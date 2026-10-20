# Runbook: Microsoft Teams debug port and mute control

The scripts read and toggle Teams microphone and camera state through the Chrome DevTools Protocol (CDP).
One event-driven watcher also supplies the Teams App Controls panel in My TouchBar My Rules (MTMR).
The reference system runs new Microsoft Teams on macOS 14.7.6 with English labels.

## Read this first: what this does to the machine

- Check organisational policy before the debug port setup.
  The reference installation lacks the supported third-party Application Programming Interface (API).
- Keep the listener on loopback.
  Any local process with port access can inspect or control Teams, beyond microphone and camera controls.
  The reference listener binds to `127.0.0.1:9333`, not an external address.
- Leave Teams open during a meeting.
  Environment changes affect only a later launch, so setup and removal require a restart outside meetings.
- Back up an existing LaunchAgent before replacement.
  Installation changes the graphical login environment for later app launches.

## How it works

1. Teams reads `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` at launch.
   The value enables port 9333 and permits WebSocket clients through `--remote-allow-origins=*`.
2. One-shot commands request `/json` from the local debug port.
   The client selects page targets under `teams.microsoft.com`, `teams.cloud.microsoft`, or `teams.live.com`.
3. The client opens a target WebSocket and uses `Runtime.evaluate` for device state or a requested toggle.
4. The microphone selector matches `[aria-label*="mic" i]` plus a label that starts with Mute or Unmute.
   “Unmute mic” means muted; “Mute mic” means unmuted.
5. The camera selector matches `[aria-label*="camera" i]` plus “Turn camera on” or “Turn camera off”.
   Those labels name the next action, not the current state.
6. A requested Document Object Model (DOM) `.click()` toggles the selected device without a focus change.

One-shot status reports `no-call` if the requested device control is absent.
The event-driven watcher instead reads `/json/version` once and keeps a browser WebSocket open.
`Target.setDiscoverTargets` reports page changes.
`Runtime.addBinding` carries MutationObserver snapshots, focus events, blur events, and visibility changes.
Navigation reinstalls the observer.

The watcher treats a hangup control or recognised device control as an active call.
The watcher selects a focused call first if multiple calls exist.
The watcher reads device labels, call controls, title, and available duration text, rather than chat messages or credentials.
Without pending work, the watcher blocks on the socket with no periodic target or DOM query.

## Install (always open the debug port)

If the LaunchAgent already exists, copy the LaunchAgent to a backup before replacement:

```bash
cp "$HOME/Library/LaunchAgents/com.maxday.teams-debug-env.plist" "$HOME/Library/LaunchAgents/com.maxday.teams-debug-env.plist.backup"
```

Install the supplied LaunchAgent:

```bash
mkdir -p "$HOME/Library/LaunchAgents"
cp teams/launchd/com.maxday.teams-debug-env.plist "$HOME/Library/LaunchAgents/"
launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/com.maxday.teams-debug-env.plist"
```

The LaunchAgent sets the environment value at login through `/bin/sh -c` and `launchctl setenv`.
After installation, quit Teams outside a meeting.
Open Teams again.
A direct `launchctl setenv` plist failed on the reference system; the shell wrapper succeeded.

Verify the listener and read-only status:

```bash
lsof -nP -iTCP:9333 -sTCP:LISTEN
curl -s --max-time 3 http://127.0.0.1:9333/json/version
teams/teams-mute status
```

If the listener uses an external address, quit Teams.
Correct the setup before further use.
The expected address is `127.0.0.1:9333`.
A shell can print an empty `launchctl getenv WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` result despite a successful setup.
Use the listener check instead.

For one launch without a LaunchAgent, use `teams/teams-debug-launch.sh [--dry-run] [--restart]`.
`--dry-run` prints commands without a launch or restart.
The script refuses if Teams already runs, unless `--restart` requests a graceful quit first.
The script waits up to about 15 seconds for the port and checks all listener addresses for loopback.
Its exit codes are 0 for success, 1 for an error/refusal, and 3 if the port never answers.

## Use

```bash
teams/teams-mute status
teams/teams-mute toggle
teams/teams-mute mute
teams/teams-mute unmute
teams/teams-mute camera-status
teams/teams-mute camera-toggle
teams/teams-mute camera-on
teams/teams-mute camera-off
teams/teams-mute discover
teams/teams-mute meeting
```

| Command | Output or action |
|---|---|
| `status` | The command prints `muted`, `unmuted`, or `no-call`. |
| `toggle` | The command toggles the microphone and prints the new state. |
| `mute` / `unmute` | The command changes state only if necessary. |
| `camera-status` | The command prints `on`, `off`, or `no-call`. |
| `camera-toggle` | The command toggles the camera and prints the new state. |
| `camera-on` / `camera-off` | The command changes state only if necessary. |
| `discover` | The command prints candidate tags and `data-tid`, `aria-label`, and `aria-pressed` attributes. |
| `meeting` | The command prints the parsed title of the call target with a microphone control. |

Current call targets use the plain meeting name.
The parser also strips the older ` | Microsoft Teams` suffix and excludes generic titles.
The parser limits the name to 80 characters.
`teams-cdp.py` accepts the same commands directly.

One-shot commands use a 3-second overall deadline and then exit.
Exit codes are 0 for success, 1 for an error, 3 for an unreachable port, and 4 outside a call.
`TEAMS_DEBUG_PORT` overrides 9333 and must contain an integer from 1024 through 65535.
All connections use `127.0.0.1`.

The actual layout starts one watcher through its `appControls` item:

```json
{
  "type":"appControls",
  "align":"right",
  "width":340,
  "switcher":"right",
  "panels":["system","teams","lob","ytmusic","praatvol","stats","fan"],
  "watcher":["${REPO}/teams/teams-watch"],
  "teams":{"directory":"${REPO}/teams"},
  "praatvol":{"app":"dev"}
}
```

`bin/tbctl layout actual` substitutes the repository path before installation.
The supervisor starts the watcher without another LaunchAgent.
`teams.directory` supplies the executable tap scripts; absent directory configuration disables the panel buttons.
The panel shows the meeting name above red elapsed time, with bordered 76-point (pt) microphone/camera buttons on the right.
Meeting-window focus selects Teams; confirmed call end restores the previous panel unless a manual choice cancels restoration.
Focus loss leaves Teams selected.

The watcher sends changed `teams` snapshots to the MTMR socket.
Connection failures retry after 5, 10, and then at most 30 seconds.
Failed state deliveries retry after 5 seconds without extra CDP requests.
The watcher sends one “Meeting joined” notification per newly observed call and never retries notifications.
The tap scripts only toggle once; watcher events confirm the resulting state.

Inspect read-only state without an MTMR connection:

```bash
teams/teams-watch --dry-run
```

Use `teams/teams-watch --socket /tmp/fake.sock` to select another MTMR socket.
The watcher accepts only those two options and help.
The supervisor logs to `~/Library/Logs/touchbar-interface/watchers.log`.
Protocol fields and selection rules appear in [app-controls.md](app-controls.md#teams).

Run fixture checks without live Teams controls:

```bash
python3 -I mtmr/tests/test-live-buttons.py
python3 -I mtmr/tests/test-teams.py
```

## Known limits

- Use Leave to end a meeting; window close can leave the call active.
  The watcher checks the hangup control and device controls, while one-shot status checks only the requested device.
- If Teams changes labels, inspect `discover` output during a call.
  Update the matching `selector`, `label`, and `states` entries in `DEVICES` inside `teams-cdp.py`.
  Current patterns require English labels.
- The duration selectors, pre-join detection, focus events, and multiple-call preference retain hardware verification notes in source.
  Without a duration element, the clock starts from the watcher's first observation of the call.
- A Teams login item can race the environment LaunchAgent; that startup order lacks verification.
- Teams can show its own grey microphone control on Apple's Touch Bar.
  The custom bar does not own that control.
- Offline state does not confirm call end.
  The panel waits for an online no-call snapshot before automatic restoration.

## Uninstall

Leave any meeting before removal.
Unload the environment LaunchAgent:

```bash
launchctl bootout gui/$(id -u) "$HOME/Library/LaunchAgents/com.maxday.teams-debug-env.plist"
rm "$HOME/Library/LaunchAgents/com.maxday.teams-debug-env.plist"
launchctl unsetenv WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS
```

Quit Teams outside a meeting.
Open Teams again.
Check that `lsof -nP -iTCP:9333 -sTCP:LISTEN` prints no listener.

The custom bar's watcher remains active and reports Teams offline if the layout still declares the watcher.
To stop the watcher, remove the `watcher` field and the Teams panel from a backed-up custom layout.
Reload that layout through an in-place write.

To restore the debug setup, reinstall the supplied LaunchAgent or restore its backup before a later Teams launch.

## Troubleshooting

| Symptom | Cause and action |
|---|---|
| The command reports an unreachable port, exit 3. | Teams may predate the environment setup. Restart Teams outside a meeting and inspect the listener. |
| The LaunchAgent appears absent. | Inspect `launchctl print gui/$(id -u)/com.maxday.teams-debug-env`. |
| Status reports `no-call` during a call. | Inspect `discover` output and `TEAMS_HOST_SUFFIXES` in `teams-cdp.py`. |
| A toggle leaves state unchanged. | Inspect matching labels and check that only the intended control matches. |
| Status remains active after window close. | The call can remain active. Select Leave in Teams. |
| The panel says “Teams offline”. | Inspect the debug listener and watcher log; connection retries cap at 30 seconds. |
| The title stays generic. | Inspect the target title and page title. The watcher accepts plain names and the older suffix. |
| The panel buttons remain disabled during a call. | Check `teams.directory` and executable permissions on both tap scripts. |
