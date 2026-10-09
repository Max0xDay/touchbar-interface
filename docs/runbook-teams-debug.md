# Runbook: Microsoft Teams debug port and mute control

Reads and toggles the Microsoft Teams microphone mute state from scripts, by talking to Teams' own web view over the Chrome DevTools Protocol (CDP).

- Last verified: 2026-10-02, new Microsoft Teams 26246.x (WebView2 / Edge 153), macOS 14.7.6, in a live call, both directions (mute and unmute, watched in the Teams window).
- Approach and original research: earlier private research notes (not included in this repo).

## Read this first: what this does to the machine

- Teams' supported "Third-party app API" is **not available** here (the setting is missing under Settings > Privacy; most likely switched off by IT). This runbook is the workaround and was chosen knowingly.
- It opens a **DevTools port on `127.0.0.1:9333`** in Teams. Any program running as this user can then read and control Teams (DOM, JavaScript, storage), not just mute. It is not reachable from other machines (verified: bound to loopback only).
- It may break your organisation's IT policy. Remove it when it is not needed (see Uninstall).

## How it works

1. Teams' web view (WebView2) reads the environment variable `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` at launch. We set it to `--remote-debugging-port=9333 --remote-allow-origins=*`. `--remote-allow-origins=*` is required, otherwise Chromium refuses connections from non-browser clients.
2. `GET http://127.0.0.1:9333/json` lists the pages. Four `teams.microsoft.com/v2/` pages exist; only the one in a call holds the mic button.
3. A WebSocket to that page's `webSocketDebuggerUrl` accepts `Runtime.evaluate`.
4. The mic button is `[aria-label*="mic" i]`. **"Unmute mic" means you are muted, "Mute mic" means you are unmuted** (the label names the next action). Clicking it with a DOM `.click()` toggles mute without focusing Teams.
5. Not in a call = no mic button = state `no-call`.

## Install (always open the debug port)

```bash
cp teams/launchd/com.maxday.teams-debug-env.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.maxday.teams-debug-env.plist
```

This sets the variable for every GUI app launched this login, at every login. Then **quit and reopen Teams once** (not during a meeting): the flag only applies at launch.

Why the plist runs `sh -c "launchctl setenv ..."`: a plist that calls `launchctl setenv` directly ran but did **not** set the variable; wrapping it in `sh -c` worked.

Verify:

```bash
lsof -nP -iTCP:9333 -sTCP:LISTEN          # one Microsoft Teams WebView line, address 127.0.0.1:9333 (never *:9333)
curl -s http://127.0.0.1:9333/json/version | head -3
teams/teams-mute status                    # no-call | muted | unmuted
```

`launchctl getenv WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` from a terminal can print nothing even when it works; use the `lsof` check, or launch a throwaway AppleScript app and read its environment.

Fallback without the LaunchAgent: `teams/teams-debug-launch.sh [--dry-run] [--restart]` starts Teams with the variable set for that one launch. It refuses to run while Teams is open unless `--restart` (which quits Teams).

## Use

```bash
teams/teams-mute status      # prints muted | unmuted | no-call
teams/teams-mute toggle      # prints the new state
teams/teams-mute mute        # no-op if already muted
teams/teams-mute unmute
teams/teams-mute camera-status   # prints on | off | no-call
teams/teams-mute camera-toggle   # also camera-on, camera-off
teams/teams-mute discover    # prints candidate mic/camera buttons (tag, data-tid, aria-label only); for fixing selectors
```

Exit codes: `0` ok, `1` error, `3` debug port not reachable, `4` not in a call. `TEAMS_DEBUG_PORT` overrides the port (default 9333). Each call connects, does one thing and exits (about 3 seconds at most); nothing runs in the background.

Only the mic button's label is read. No page content, messages or tokens are read, printed or stored.

For the live Touch Bar mic, `teams/teams-watch` polls this status and updates one
id-bearing button through MTMR's socket (green unmuted, red muted, yellow unreadable,
hidden/collapsed outside a call). Manual background use, fake-test options, the
absolute-path tap action and an uninstalled LaunchAgent illustration are documented
in [live-buttons.md](live-buttons.md). No Teams restart is required for the watcher.

## Known limits

- **Call end is detected by the mic button disappearing.** If you only close the meeting window, Teams can keep the call alive and `status` keeps answering. Leaving the call is the reliable end. The call page also has a `Leave` button (`data-tid="hangup-main-btn"`) that could be used as a second signal; not implemented.
- Teams updates can rename the labels. Run `discover` in a call and fix `MIC_BUTTON_SELECTORS`, `MUTED_LABEL_PATTERN` and `UNMUTED_LABEL_PATTERN` at the top of `teams/teams-cdp.py`. Labels are English; a different Teams language would need new patterns.
- Untested: Teams as a login item racing the LaunchAgent at boot (the variable might not be set yet on the first launch after login).
- Teams adds its own grey mute button to the Touch Bar during calls; it is not ours and not controlled by this.

## Uninstall

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.maxday.teams-debug-env.plist
rm ~/Library/LaunchAgents/com.maxday.teams-debug-env.plist
launchctl unsetenv WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS
```

Then quit and reopen Teams; `lsof -nP -iTCP:9333 -sTCP:LISTEN` must print nothing.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `status` says `teams-cdp: debug port 9333 not reachable` (exit 3) | Teams was started before the variable was set, or the LaunchAgent is not loaded. Quit and reopen Teams; check `launchctl print gui/$(id -u)/com.maxday.teams-debug-env`. |
| `status` says `no-call` in a call | Selectors or host list changed. Run `discover`; check the call page host is in `TEAMS_HOST_SUFFIXES` in `teams-cdp.py`. |
| `toggle` prints a state but Teams did not change | Clicked the wrong element. Run `discover` and confirm there is exactly one mic button in the call page. |
| `status` still answers after you left | The call window was closed, not left. Use Leave. |
