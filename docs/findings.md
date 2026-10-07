# Findings

Facts established while building this project. Each fact says how it was established:

- **Verified:** observed on the real machine.
- **Source:** read in code or documentation.
- **Unverified:** believed, not tested.

Machine: MacBook Pro 13" (M1, 2020), macOS 14.7.6, Touch Bar. This is a work laptop: back up before you change anything.

Last cleaned: 2026-10-07. The history of each build step is in git.

---

## 1. MTMR (My TouchBar My Rules)

Repo: https://github.com/Toxblh/MTMR (MIT licence).

- The last release (v0.27.0, 2020) and the Homebrew cask are Intel-only and need Rosetta 2. (Source: `gh release list`, `brew info --cask mtmr`.)
- Upstream commit `94fc98c` (2026-05-15) added arm64 support. No release contains it. We build that commit. (Source.)
- Rosetta 2 is not installed on this machine, and it must stay that way. (Verified.)
- The config is `~/Library/Application Support/MTMR/items.json`. MTMR reloads it on every write through a file-descriptor watcher. Write the file in place: an atomic replace breaks the watcher. (Source, Verified.)
- A config reload rebuilds the whole bar and the bar flickers. Use the socket for live state. (Verified.)
- MTMR has no push interface of its own: no URL scheme, no AppleScript dictionary, no socket. Our socket is the push path. (Source.)
- Item options on every item: `width`, `align`, `bordered`, `background`, `title`, `image`, `matchAppId`, `actions`. `group` opens a sub-bar. (Source.)
- MTMR recreates the items on every app activation. Timers in a view must start only when the view is in a window. (Source.)
- The bar shows a short flicker on some app switches. We think MTMR itself causes the flicker. Presenting only on change did not remove it. (Verified, cause unverified.)
- The ✕ (`exitTouchbar`) minimizes our bar. The MTMR icon on Apple's bar opens it again. (Verified.)
- The Do Not Disturb item does not work on macOS 14.7.6. (Verified.)

## 2. Touch Bar facts

- Our bar owns the whole width: `showControlStrip` is unset, so Apple's control strip is not shown. (Verified.)
- **The host view of our bar is 1004 x 30 pt, not 1085.** 1085 is only the fallback in the solver. (Verified from logs.)
- With App Controls at 340 pt, the notification area is 292 pt wide, below its 358 pt minimum (the solver logs a warning). The widest right zone without the warning is (1004 − 358 − 32) / 2 = 307 pt. (Verified.)
- The Touch Bar ignores `contentTintColor`. Tints must be drawn into the image. (Verified: the muted mic stayed white before the fix.)
- A view with alpha 0 still receives touches. Hidden buttons must also set `isHidden`. (Verified: a hidden mic button blocked ✕.)
- Only horizontal finger movement reaches the notification area. Vertical swipes are not reported. (Verified.)

## 3. Native build with the Command Line Tools (Verified)

- The Command Line Tools SDK ships link stubs for `DFRFoundation`, `MultitouchSupport`, `CoreBrightness` and `CoreDisplay`.
- The storyboard holds only the main menu, so `ibtool` is not needed.
- The code uses 12 asset-catalogue images through `#imageLiteral`. Without them the app crashes at startup. They ship as plain PNGs behind a small loader, so `actool` is not needed.
- Sparkle (the auto-updater) is removed.
- The deployment target is macOS 11. APIs from macOS 12 and later (`systemCyan`, `kIOMainPortDefault`) do not compile.
- Ad-hoc signing changes the signature on each build. The Accessibility permission must be reset and granted again after every rebuild. A stale permission shows in the TCC log as `Failed to match existing code requirement`. Without the permission, VS Code windows read as "No windows". (Verified 2026-10-07.)

## 4. Data sources for App Controls (Verified 2026-10-06/07)

- **YouTube Music:** Pear Desktop (`com.github.th-ch.youtube-music`). The private MediaRemote framework works without entitlements on 14.7.6: title, artist, artwork, duration, elapsed time, rate.
- **CPU temperature without sudo:** the private IOHIDEventSystem API, sensors `pACC MTR Temp*` and `eACC MTR Temp*`. **The IOHIDEventSystemClient must stay alive** while its services are used. A freed client crashed MTMR at launch.
- **VS Code windows:** Accessibility gives the title ("file — project") and `kAXDocument` (the file URL).
- **Notification Center database:** `$(getconf DARWIN_USER_DIR)com.apple.notificationcenter/db2/db` is readable without Full Disk Access. `record.data` is a binary plist with `req.titl`, `req.subt` and `req.body`. `rec_id` is reused, so new records are found by `delivered_date` and de-duplicated by uuid. A record disappears when the user dismisses the notification.
- **kitty notifications from inside tmux:** tmux `allow-passthrough` is off. Writing OSC 99 to the tmux client tty (`tmux display -p '#{client_tty}'`) works.
- **lob sessions:**
  - `lob.sh` starts `tmux new-session -s <project>-NN -- claude … "Active project: <project>. …"`.
  - Working shows a spinner line, for example "✢ Tinkering… (thought for 2s)". Done shows "✻ Baked for 3s · done 3:30 PM".
  - "esc to interrupt" is truncated in narrow panes, so it is not a reliable signal.
  - Two sessions run on an orphaned tmux server (pid 7137). Its socket was replaced, so tmux cannot reach them. Never send that server SIGUSR1: it would fight the current server for the default socket.
  - Working Claude uses about 12 % CPU. Idle Claude uses 0.3–3.7 %, with short spikes to about 8 %. A CPU-based guess needs an average over several seconds.

## 4a. Fans and ThermalForge (2026-10-07)

- The machine has one fan, 1199–7199 rpm. Under Apple's control it stays at 0 rpm at light load, with CPU sensors at 50–60 °C. (Verified, `thermalforge status`.)
- Apple publishes no fan curve. On Apple Silicon the SMC and `thermalmonitord` run a closed loop over many sensors, including estimated surface temperatures. (Unverified: no Apple documentation found.)
- Macs Fan Control had been removed, but its root helper `com.crystalidea.macsfancontrol.smcwrite` was still running and held the fan in manual mode at about 4,500 rpm. We removed it. Backup: `backups/macsfancontrol-20261007/` (outside the repo). (Verified.)
- ThermalForge from Homebrew needs full Xcode on macOS 14. The CLI builds with the Command Line Tools: `swift build -c release --product thermalforge` at commit `42bb534`. (Verified.)
- `thermalforge install` (sudo) copies the binary to `/usr/local/bin` and installs the LaunchDaemon `com.thermalforge.daemon` with the installing user's UID. The socket `/var/run/thermalforge.sock` belongs to that user (mode 0600), so MTMR connects without sudo. (Verified.)
- The daemon knows only fan speeds (`set`, `setfan`, `max`, `auto`) plus `status`, `state`, `heartbeat` and `version`. ThermalForge's profiles live in its menu bar app. (Source.)
- Safety: full fan speed at 95 °C on the hottest CPU/GPU sensor; a supervised hold without a heartbeat for 15 s goes back to Apple's control. A CLI `thermalforge set` is unsupervised: the watchdog never reverts it. (Source.)
- Writes are rate-limited (burst 20, 10 per second); `auto` is exempt. (Source.)
- An SF Symbol drawn as a template image turns black when the App Controls switcher redraws it as a non-template image. Bake the colour into the icon. (Verified.)

## 4b. kitty notifications from tmux (2026-10-07)

- tmux 3.7c drops OSC 99 unless `allow-passthrough` is on. It is a pane option: `set -gw allow-passthrough on` works, `set -g` does not. Set in `~/.tmux.conf`. (Verified.)
- Through tmux, OSC 99 must be wrapped: `ESC P tmux; <OSC with every ESC doubled> ESC \\`. (Verified: notification shown.)
- In OSC 99, `d=0` means "more parts follow": kitty shows nothing until a part without `d=0` arrives, then joins all parts. (Verified.)
- kitty stores its notifications with the body `" "` (one space). The mirror trims title and body, so they show as one-line entries. (Verified in the database.)
- Notifications do not show while macOS holds them back during a meeting (screen sharing or Focus). (Verified 2026-10-07.)

## 5. Microsoft Teams (Verified unless marked)

Approach: `/Users/maxday/Workspace/projects/theboxstuff/cliui/daemon/docs/teams-debug-port-approach.md`.

- The Teams third-party app API is not available here (likely disabled by IT). The debug port is a deliberate workaround: any local process can control Teams through it, and it may break IT policy.
- `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--remote-debugging-port=9333 --remote-allow-origins=*"` opens a DevTools port on `127.0.0.1:9333` only. A LaunchAgent sets the variable at login. The plist must wrap `launchctl setenv` in `sh -c`. `launchctl getenv` from a shell reads empty and is not a valid check.
- The in-call mic button is `[aria-label*="mic" i]`. "Unmute mic" = muted, "Mute mic" = unmuted. `.click()` toggles mute without stealing focus. English UI only.
- `[aria-label*="mic" i]` alone also matches "Microsoft …" labels in the main window, outside calls. The script therefore takes only a match whose label starts with "Mute" or "Unmute". Before this fix the yellow unknown button showed with no call. (Verified 2026-10-07.)
- The in-call camera button is labelled "Turn camera on" (camera off) or "Turn camera off" (camera on). `.click()` toggles it. A second button "Open video options" also matches "video". (Verified 2026-10-07.)
- The target title of the call window is "<meeting title> | Microsoft Teams". `teams-mute meeting` prints the meeting title.
- Closing the meeting window can leave the call running. The Leave button (`data-tid="hangup-main-btn"`) is a candidate signal for "call ended". (Unverified.)

## 6. Outlook (Verified 2026-10-07)

- Outlook meeting reminders are **not** macOS notifications. They appear only in Outlook's own reminder window and never reach the Notification Center database.
- The Outlook menu bar extra (Accessibility `AXExtrasMenuBar`) shows "8m: <title>" or "Now: <title>". This is a possible fallback.
- Preferred future approach: the calendar's iCal link (parked).
