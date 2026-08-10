# Updating a Pi by hand (SSH)

The normal way to update the fleet is **Sync** on <https://v2.qmed.asia/admin/raspberry-pi>.
Use this page when you want to test a change on one device first, or when the
server has not published the new bundle yet.

```bash
ssh qmed@192.168.0.19
```

---

## The one thing to understand

| Folder | What it is |
|--------|------------|
| `~/.qmed/` | **What the Pi actually runs.** Cron and the kiosk load from here. |
| `~/Desktop/raspberry_pi_v2.1/` | Just a staging copy. Only `setup.sh` reads it, during provisioning. |

Updating the Desktop folder alone changes **nothing** on screen. You must copy
the files into `~/.qmed/` and restart.

---

## First time only — turn the staging folder into a git clone

If the folder arrived by `scp` it has no `.git`, so `git pull` fails with
*"not a git repository"*. Fix it once:

```bash
command -v git >/dev/null || sudo apt-get install -y git
cd ~/Desktop && mv raspberry_pi_v2.1 raspberry_pi_v2.1.scp-old
git clone https://github.com/kelvinric123/rasberry_pi_deploy.git raspberry_pi_v2.1
```

Then install the one-line updater:

```bash
printf '#!/bin/bash\ncd ~/Desktop/raspberry_pi_v2.1 && git pull --ff-only && cp server.py start_local_server.sh video_sync.sh scenery_sync.sh heartbeat.sh kiosk.sh net_watchdog.sh self_update.sh ~/.qmed/ && chmod +x ~/.qmed/*.sh ~/.qmed/*.py && bash ~/.qmed/start_local_server.sh && pkill -f -- "--kiosk"; echo "updated to $(git -C ~/Desktop/raspberry_pi_v2.1 rev-parse --short HEAD)"\n' > ~/qmed-update
chmod +x ~/qmed-update
```

---

## Every time after that

```bash
~/qmed-update
```

That pulls, copies the 8 bundle files into `~/.qmed/`, and restarts the local
server and the kiosk. The screen goes black for a few seconds.

---

## Without git (no staging folder needed)

Downloads straight from the public repo into `~/.qmed/`:

```bash
cd ~/.qmed && for f in server.py start_local_server.sh video_sync.sh scenery_sync.sh heartbeat.sh kiosk.sh net_watchdog.sh self_update.sh; do
  curl -fsSL -o "$f" "https://raw.githubusercontent.com/kelvinric123/rasberry_pi_deploy/main/$f" && echo "ok   $f" || echo "FAIL $f"
done
chmod +x ~/.qmed/*.sh ~/.qmed/*.py
bash ~/.qmed/start_local_server.sh; pkill -f -- '--kiosk'
```

---

## Back up first (optional, one command to undo)

```bash
cp -a ~/.qmed ~/.qmed.bak-$(date +%Y%m%d-%H%M)
```

Roll back:

```bash
rm -rf ~/.qmed && mv ~/.qmed.bak-* ~/.qmed
bash ~/.qmed/start_local_server.sh; pkill -f -- '--kiosk'
```

---

## After adding a NEW script

A manual copy does not create cron entries — `setup.sh` and `self_update.sh`
normally do that. `scenery_sync.sh` (screen-saver scenery) needs one:

```bash
(crontab -l 2>/dev/null | grep -v scenery_sync; echo "17 */6 * * * $HOME/.qmed/scenery_sync.sh") | crontab -
mkdir -p ~/.qmed/videos/scenery && bash ~/.qmed/scenery_sync.sh
```

---

## Check it worked

```bash
crontab -l | grep -E "heartbeat|watchdog|scenery|video_sync"   # 4 jobs expected
ls ~/.qmed/*.sh ~/.qmed/*.py                                    # the bundle
ls ~/.qmed/videos/scenery | head -3                             # scenery cached
bash ~/.qmed/net_watchdog.sh; tail -5 ~/.qmed/net_watchdog.log  # silence = healthy
```

Useful logs:

```bash
tail -f ~/.qmed/self_update.log      # updates
tail -f ~/.qmed/net_watchdog.log     # network / page recovery
tail -f ~/.qmed/kiosk.log            # Chromium launches
tail -f ~/.qmed/video_server.log     # local server on :8888
```

---

## ⚠ The catch with manual updates

`~/.qmed/scripts_version` still holds the **old** hash, because only
`self_update.sh` stamps it. So:

* the admin page keeps showing this Pi as **"Scripts outdated"** — it is
  reporting honestly, since it is not running the bundle the server publishes
* **do not press Update or Sync on this device** — it will download the
  server's copy straight over your manual files

Manual install and server-driven update fight over the same files, and the
server always wins. Once the server publishes the same bundle, press Update on
this device once and everything lines up again.

---

## Common problems

| Symptom | Cause / fix |
|---------|-------------|
| `git pull` → *not a git repository* | The folder came from `scp`. Do the one-time clone above. |
| `~/qmed-update` → *cannot pull with rebase* / conflict | Someone edited files on the Pi. `git -C ~/Desktop/raspberry_pi_v2.1 reset --hard origin/main` then re-run. |
| Screen stays black after an update | `pkill -f -- '--kiosk'` again; `kiosk.sh` relaunches within seconds. If not: `tail ~/.qmed/kiosk.log`. |
| Screen saver shows nothing | `bash ~/.qmed/scenery_sync.sh` and check the server publishes a pack: `curl -s https://v2.qmed.asia/screensaver/manifest.json` |
| No sound | Default sink is probably the AV jack. `wpctl status` — the `*` should be on the HDMI sink, not "Built-in Audio Stereo". `wpctl set-default <id>`. |
| Page stuck on an error | The 1-minute page watchdog reloads it. Force now: `bash ~/.qmed/net_watchdog.sh` |
