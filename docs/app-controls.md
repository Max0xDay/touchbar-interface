# App Controls

App Controls is the zone on the right end of the bar. The zone shows one **panel** at a time. A panel is a small control surface for one app or topic, for example YouTube Music or Stats.

The user picks the panel, and the choice stays the same after a restart or a layout reload. Teams is the one focus-driven exception: focusing a meeting window selects Teams; ending the call restores the previous panel unless the user has manually selected a panel during the call. Blur never switches away.

```
[✕][gap][ left buttons ] |  [ notification area ]  | [ panel ............................ ][SW]
                                                        switcher button: icon of the current panel ─┘
```

## Panels

| Panel | ID | Icon | Contents | Tap |
|---|---|---|---|---|
| System | `system` | Clock tile (graphite tile, white clock at 10:10) | Three columns: time with seconds, weekday over date, and a bullet list with the ISO week and battery level. | Nothing |
| Teams | `teams` | Teams app icon, or graphite people tile | Meeting title over elapsed time, with mic and camera buttons; grey “No meeting” or “Teams offline” otherwise. | Mic/camera: toggle without focusing Teams. Meeting-window focus selects this panel automatically. |
| YouTube Music | `ytmusic` | Pear app icon | Cover, title, artist, a thin progress line, and the previous / play-pause / next buttons. | Cover or title: brings Pear to the front, or opens Pear if it does not run. |
| VS Code | `vscode` | VS Code icon | A window toggle, a Run button (▶), and a command button (⌘). The window toggle shows the current window in the colour of that window: a colour stripe, the project name, the open file, and one coloured dot for each window. The current window has the large dot with a white ring. | Window toggle: goes to the next window. If VS Code is not in front, the first tap brings the current window to the front. Run: presses F5 (Run > Start Debugging). Command button: opens the Command Palette (⇧⌘P). |
| praatvol | `praatvol` | Waveform tile (graphite tile, white waveform; switcher only) | Full-width Room/Call buttons when idle. Recording: red pulsing dot, elapsed time, Room/Call pill, microphone and signal dots. Processing: spinner and progress line. Review: “Transcribe?” with duration/size or a warning. Offline: centred grey text. Saved: green check for 4 s. | Room/Call: start recording. Stop: tap twice within 3 s while recording, once during setup. Review checkmark: Transcribe; cross: Skip (keep audio only). |
| Stats | `stats` | Stats app icon | Four cells: CPU (a ring with the total and a heat grid with one square for each core: efficiency cores on top, performance cores below), MEM (a ring with the %), TEMP (a thermometer and the CPU temperature), and NET (download and upload rate). | Opens the Stats app. |
| lob | `lob` | Terminal tile (orange ">_" on black) | One pill for each lob session: a blue spinner while Claude works, a slow purple arc while pi-delegate runs, a pulsing green dot when Claude finishes and waits for a reply, a grey dot when idle. Always a two-row grid with the same cell size as 4 sessions: 3 sessions leave the top-left cell empty, 1 to 2 stack in the left column, 5 or more add columns. | Nothing |
| Fan | `fan` | Fan tile (graphite tile, white fan) | A mode button (Apple, Quiet, Cool, Max, Custom); a graph of the last 2 minutes: the temperature line, the actual fan speed (blue area), the speed the mode asks for (dashed blue), and dashed lines at the mode's thresholds (fan on, full speed) and at the 95 °C floor (red); the temperature over the fan RPM. Temperature uses 30–100 °C and fan speed 0–100 % of the same height. In Custom, the graph is replaced by a slider. | Mode button: opens a row with all five modes (current one in the accent colour); tap one to select it. The row closes after 6 s. Custom: touch or drag the slider to set the fan speed. |

If no panel is selected, App Controls shows the System panel.

## Use the switcher

1. Tap the switcher button (the app icon at the right edge of the zone).
2. A row of panel icons replaces the panel. The current panel has the accent colour.
3. Tap a panel icon to select that panel.

To close the row without a change, tap the switcher button (✕) again. The row closes by itself after 6 seconds.

## Colours

- All buttons use the standard grey Touch Bar style. The switcher has no frame: the app icon fills the full bar height (30 pt).
- All glyph icons use one fixed 18 pt box, centred on the same line (`TouchBarIcon.swift`). App icons in the switcher row use 24 pt.
- The Touch Bar ignores the button tint setting (`contentTintColor`). Each icon has its colour drawn into the image.
- The system accent colour marks the selected item.
- Green, orange, and red show state only. For example, a meter turns orange above 70 % and red above 90 %. The temperature meter turns orange at 80 °C and red at 92 °C.

## Data sources

- **YouTube Music:** the player is Pear Desktop (bundle ID `com.github.th-ch.youtube-music`). The panel reads macOS Now Playing through the private MediaRemote framework. Pear publishes title, artist, cover, and play state there. The panel needs no Pear plugin. The Pear API Server plugin stays off.
- **Play controls:** the buttons send commands to the Now Playing app. If a different app plays media at that time, the buttons control that app. If MediaRemote is not available, the buttons send the media keys.
- **VS Code windows:** the panel reads the title and the open document of each window through the Accessibility API. MTMR already has the Accessibility permission. A title such as "file.swift — project" gives the project name "project".
- **Window colours:** the colour key is the project folder path. The panel takes the path of the open document up to the folder with the project name, for example `/Users/you/projects/my-project`. If the window has no document, the key is the project name. A stable hash of the key selects one of eight system colours (blue, purple, pink, orange, teal, green, indigo, yellow). Red is not in the list, because red means "muted" or "problem" on this bar. The colour of a window stays the same when you change files and after a restart. Two projects can get the same colour.
- **Window order:** the panel sorts the windows by folder path, so the order stays the same when the focus changes.
- **Stats:** the Stats app has no Application Programming Interface (API). The panel reads the same data directly:
  - CPU: the load of all cores between two refreshes.
  - RAM: app memory, wired memory, and compressed memory, divided by the physical memory. Activity Monitor calls this value "Memory Used".
  - Temperature: the mean of the performance-core and efficiency-core sensors (`pACC` / `eACC`). These are the same sensors that the Stats app uses on M1.
  - GPU: "Device Utilization %" of the graphics accelerator (IOAccelerator).
  - NET: the byte counters of all network interfaces except loopback, between two refreshes.

## praatvol

The panel reads the praatvol control socket, not the MTMR socket. Release uses `~/Library/Application Support/praatvol/control.sock`. Dev uses `~/Library/Application Support/praatvol-dev/control.sock`.

Set `"praatvol": {"app": "dev"}` on the `appControls` layout item to use dev. `"release"` is the default. The everyday layout uses dev for now. VS Code stays registered and can be restored to the layout.

The protocol is newline-delimited JSON, at most 4 KiB per line. One `subscribe` connection receives a snapshot on connection, on changes and every second while recording. The client accepts wrapped `{"ok":true,"status":...}` replies and bare snapshots. It reconnects after 2 s while the panel is on the bar and disconnects when the panel leaves the bar. New snapshot fields are optional and may be null; v1 snapshots without them still work. Unknown step strings show a spinner and the capitalised step name rather than failing the connection.

The panel is 30 pt tall, with 8 pt horizontal gaps and measured, vertically centred text rows. There is no left-hand waveform glyph; the tile remains in the switcher only. Text never shrinks and long labels truncate with an ellipsis.

| State | Display and controls |
|---|---|
| Offline | Centred grey “praatvol offline” across the panel. |
| Idle / failed | Two equal-width neutral buttons fill the panel: mic + Room and phone + Call. A failed run adds a small red dot inside the Room button. |
| Starting | Spinner + “Starting”, with a Stop button that cancels on one tap. |
| Recording | Row 1: pulsing red dot, monospaced elapsed time and grey Room/Call pill. Row 2: microphone name and signal dots. Stop is 30 pt tall with a red glyph; first tap shows red “Stop?” for 3 s, second tap sends stop. |
| Preparing / uploading / transcribing | Spinner and a 12 pt label above a thin rounded progress line. Preparing uses `preparingFraction`; uploading uses `uploadFraction` and shows a percent. Transcribing estimates `(now - stepStartedAt) / estimatedSeconds` locally each second, capped at 95%, with a `~` prefix. Missing fractions or estimate fields leave the track empty and the spinner running, with no percent. Preparing/uploading cap at 99% while the step is active; no step shows 100% before changing. |
| Review | “Transcribe?” above duration (`mm:ss` or `h:mm:ss`) and size (decimal MB, one decimal), omitting missing values. If `warnings` is non-empty, an orange triangle and the first truncated warning replace the detail row. Two 56 pt buttons: green checkmark (Transcribe) and neutral cross (Skip). They remain until a pushed snapshot changes the state. |
| Needs attention | Orange triangle inline with “Needs attention on Mac”; command buttons are disabled. |
| Saved | Green check + “Saved” for 4 s from local receipt of the step change, then the idle buttons. Repeated saved snapshots do not extend the flash. |

Buttons send `record-room`, `record-call`, `stop`, `transcribe` or `keep` on short-lived background connections. Review checkmark sends `{"cmd":"transcribe"}`; Skip sends `{"cmd":"keep"}` to save audio without transcription. Both are valid only in review. Commands are not retried or shown optimistically. Command errors show a short message for 2 s; `notReviewing` shows “Already answered”. Green signal dots mean audio is present, hollow grey dots mean silence, and orange means more than 10 s of silence.

Review and the new progress fields require praatvol to implement control protocol addendum v1.1 (`stepStartedAt`, `estimatedSeconds`, `preparingFraction`, `durationSeconds`, `uploadBytes`, `warnings`). Until then the old flow remains supported; no review controls appear unless praatvol pushes `review`.

Focused checks: `python3 -I mtmr/tests/test-praatvol.py`. The normal test runner discovers this test automatically. Tests use only a temporary fake socket.

## Teams

The everyday layout runs one `teams/teams-watch` process from the `appControls` item's `watcher` field. The supervisor already accepts watchers on any top-level item; no live-button placeholder is needed. Set `"teams": {"directory": "${REPO}/teams"}` on the item so the panel can run the existing tap scripts (absolute executable paths after `tbctl layout` substitution). Without that option the readout works, but taps are disabled.

The watcher opens `/json/version` once per connection to `127.0.0.1:9333`, then keeps the browser CDP websocket open with `Target.setDiscoverTargets`. It attaches to eligible Teams pages, including the main page so a call appearing within an existing page is detected. `Runtime.addBinding` carries MutationObserver snapshots of call UI and mic/camera labels, plus window focus/blur and visibility changes. Navigation reinstalls the observer. There is **no target-list polling or DOM polling**, including outside calls. Unreachable/disconnected CDP retries after 5, 10, then 30 seconds maximum. Failed MTMR state deliveries retry after 5 seconds without making CDP requests; join notifications are never retried.

One newline JSON message is sent per changed state through the normal MTMR socket:

```json
{"cmd":"teams","online":true,"inCall":true,"title":"Weekly sync","mic":"on","camera":"off","focused":true,"joinedAt":1792400000,"durationText":"12:03"}
```

`inCall` is required and boolean. `online` defaults to true; `focused` to false; title to empty; mic/camera to unknown. Optional `joinedAt` is epoch seconds; `durationText` is `mm:ss` or `h:mm:ss`, or null. Invalid field types reject the entire message with the usual error reply. Unknown fields are ignored and unknown device strings render grey. `{"cmd":"teams","online":false,"inCall":false}` marks the watcher offline. Offline is not a confirmed call end, so restoration waits for an online no-call report.

In-call text is 12 pt semibold over 10 pt grey elapsed time; the title truncates, never shrinks. The two 44 × 30 pt neutral buttons use baked green/red symbol tints and grey for unknown state. The local clock ticks once per second, synchronising to Teams' DOM duration when available and otherwise using first-seen `joinedAt`. Timer selectors (`call-duration`, `call-timer`, `call-duration-text`) and meeting-window focus events still need real-call verification; the join timestamp is a fallback, not historical time before the watcher started. A “Meeting joined” notification is sent when a call is first observed, including startup during a call.

Tap scripts run asynchronously, with optimistic icons until watcher confirmation (at most 5 seconds), a 6-second process timeout, and no toggle retries. Errors are logged and revert the optimistic icon. A manual switcher or `tbctl app` selection cancels restoration and suppresses automatic re-selection for the remainder of that call. No selection happens outside a call, and blur keeps Teams selected.

Focused checks: `python3 -I mtmr/tests/test-live-buttons.py` and `python3 -I mtmr/tests/test-teams.py`. Read-only idle trace: 20 seconds against the live debug port with no meeting produced one no-call snapshot; CPU stayed 0.0% and process CPU time stayed 0:00.28 from second 3 to second 20. All traced CDP requests were discovery, attachment and observer setup within the first 0.048 seconds; no requests followed during the remaining idle run. Call transitions (including pre-join/leave detection), focus, controls and appearance remain hardware checks; development never clicked Teams.

Rollback: restore the source/layout from the pre-change backup, rebuild, then explicitly install the old layout and restart MTMR yourself. The installed `items.json` is not changed by builds or tests.

## Fan

The fan panel needs the ThermalForge daemon (`/usr/local/bin/thermalforge`, LaunchDaemon `com.thermalforge.daemon`). The daemon runs as root and writes the fan speed to the SMC. MTMR talks to it on `/var/run/thermalforge.sock` (4-byte length + JSON, only the installing user may connect). The curves are in `FanController`, not in ThermalForge.

| Mode | Behaviour |
|---|---|
| Apple | Apple's own fan control. MTMR sends `auto` once and then does nothing. |
| Quiet | Off below 70 °C, then up to 50 % at 90 °C (ease-in). Trades heat for noise. |
| Cool (default) | Off below 45 °C, then up to 100 % at 75 °C (ease-in). |
| Max | Full speed. |
| Custom | A fixed speed set with the slider. At 85 °C the mode switches to Cool and a notification appears. |

- The temperature is the hottest CPU or GPU sensor (`TC*`, `Tp*`, `TG*`, `Tg*`), the value that the daemon's safety floor uses, smoothed over a few samples.
- Below the start temperature the fan goes back to Apple (`auto`). A running fan stops only 5 °C below the start temperature.
- The controller runs every 2 s while the zone is loaded, also when another panel shows. It writes a speed only when the speed changes by 100 rpm or more, and it slows down by at most 300 rpm per step. Otherwise it sends a heartbeat.
- Safety: the daemon sets the fans to full speed at 95 °C in every mode. If MTMR stops, the daemon gives the fans back to Apple after 15 s. `thermalforge auto` does the same at once.
- The mode and the Custom speed persist (UserDefaults `FanMode`, `FanCustomPercent`).

```bash
bin/tbctl fan                 # mode, temperature, rpm
bin/tbctl fan quiet           # set the mode
bin/tbctl fan custom --percent 30
```

## lob sessions

- The panel finds lob sessions from the running Claude processes. lob starts each one as `claude … Active project: <name>. …`. The pill shows the tmux session name without `-01` (`-02` shows as `<name> 2`).
- An older tmux server can lose its socket when a newer server starts. tmux commands then cannot reach its sessions. The panel still lists those sessions, because it starts from the process list.
- **Working:** Claude shows a spinner line above the prompt, for example "✢ Tinkering… (thought for 2s)". The monitor looks for a glyph, a capitalised word, and "…" in the 12 lines above the "❯" prompt. If tmux cannot reach the session, the monitor uses CPU instead: an average of 8 % or more over 6 s means working. Idle Claude has short CPU spikes, so a CPU working spell under 15 s goes back to idle, not to finished.
- **Delegate:** a process that runs `pi-delegate.py --tier` is somewhere below the session's Claude process. Delegate takes priority over working.
- **Finished:** the session was working and stopped. The chip stays green until Claude works again, or for 30 minutes.
- **Idle:** all other sessions.
- The monitor reads tmux every 1.5 s. It starts when the zone loads, so it sees a finish while another panel shows.
- lob needs no change. A tap on a chip does nothing.

## Layout entry

```json
{
  "type": "appControls",
  "align": "right",
  "width": 340,
  "switcher": "right",
  "panels": ["system", "teams", "lob", "ytmusic", "praatvol", "stats", "fan"],
  "watcher": ["${REPO}/teams/teams-watch"],
  "teams": {"directory": "${REPO}/teams"},
  "praatvol": {"app": "dev"}
}
```

- `switcher` is optional: `"right"` (the actual layout) or `"left"` (the default).
- `panels` is optional. The list sets the order in the switcher. An unknown ID makes MTMR reject the layout.
- `width` sets the width of the zone. The solver never shrinks right-hand items. Our bar is 1004 pt wide (measured). Keep the width at or below `(1004 − notification minWidth − 2 × 16) / 2`. With `maxChars: 36`, the limit is 307. At 340, the notification area is 292 pt, below its minimum, and MTMR logs a layout warning.

## Socket commands

```bash
bin/tbctl app            # list the panels and show the selected one
bin/tbctl app stats      # select a panel
```

Protocol: `{"cmd":"app","id":"stats"}` and `{"cmd":"apps"}`. MTMR registers these commands when the loaded layout has an `appControls` item.

## Add a panel

A panel is one Swift file in `mtmr/overlay/`. The file holds a `final class` that inherits `NSView` and conforms to `AppControlsPanel`:

```swift
final class AppControlsExamplePanel: NSView, AppControlsPanel {
    static let id = "example"            // [a-z0-9-], unique
    static let name = "Example"          // tooltip and `tbctl app` list
    static func icon() -> NSImage { return appControlsTextBadge("EX") }
    let refreshInterval: TimeInterval = 2

    override init(frame frameRect: NSRect) { super.init(frame: frameRect) /* add subviews */ }
    required init?(coder: NSCoder) { return nil }
    override func layout() { super.layout() /* frames inside bounds (height 30) */ }
    func refresh() { /* read data, update subviews */ }
}
```

Follow these steps:

1. Add the class to `AppControlsRegistry.panels` in `AppControlsItem.swift`.
2. Add the ID to `panels` in `layouts/actual.json`.
3. Run `mtmr/build.sh` and restart MTMR.

Follow these rules for a panel:

- Use the helpers in `AppControlsKit.swift`: `AppControlsStyle` for labels, buttons, and colours, `AppControlsApps` for app icons and app launches, and `AppControlsMeterView` for meters.
- Keep `refresh()` fast. `refresh()` runs on the main thread. Use an asynchronous call for slow data, as `NowPlaying` does.
- Let the zone drive periodic `refresh()` calls only while the panel is on the bar. Short action timers, such as Stop confirmation, must be cancelled when the panel leaves the bar.

## Files

| File | Contents |
|---|---|
| `mtmr/overlay/AppControlsItem.swift` | Panel protocol, registry, selection, zone view, switcher |
| `mtmr/overlay/AppControlsKit.swift` | Shared style, app helpers, key presses, meter view, text badge |
| `mtmr/overlay/TouchBarIcon.swift` | One icon size for the whole bar; colour drawn into the icon |
| `mtmr/overlay/AppControlsSystemPanel.swift` | System panel |
| `mtmr/overlay/AppControlsTeamsPanel.swift` | Teams panel, pushed state and asynchronous tap actions |
| `mtmr/overlay/TeamsState.swift` | Teams decode, elapsed clock and automatic selection policy |
| `mtmr/overlay/AppControlsMusicPanel.swift` | `NowPlaying` (MediaRemote) and the YouTube Music panel |
| `mtmr/overlay/AppControlsCodePanel.swift` | VS Code panel |
| `mtmr/overlay/AppControlsPraatvolPanel.swift` | praatvol panel, recording readout and Stop confirmation |
| `mtmr/overlay/PraatvolClient.swift` | praatvol socket client, options, snapshots, line framing and display model |
| `mtmr/overlay/AppControlsStatsPanel.swift` | Stats panel, `SystemMetrics`, temperature sensors |
| `mtmr/overlay/AppControlsLobPanel.swift` | lob panel, `LobMonitor`, session chips, lob icon |
| `mtmr/overlay/AppControlsFanPanel.swift` | Fan panel, `FanController` (curves), `ThermalForgeClient` (daemon socket) |
| `mtmr/overlay/NotificationMirror.swift` | Mirror of macOS notifications into the notification area |
| `mtmr/patches/0005-app-controls-watchers-welcome.patch` | `appControls` item type, watchers, welcome notification |
