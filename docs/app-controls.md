# App Controls

App Controls occupies the right end of the Touch Bar in My TouchBar My Rules (MTMR).
The zone shows one panel for an app or topic at a time.
The selected panel persists in UserDefaults under `AppControlsPanel` across restarts and layout reloads.

The user selects panels through the switcher or the socket.
Teams provides one automatic exception: meeting-window focus selects Teams once per call.
Call end restores the previous panel unless a manual selection cancels restoration.
Focus loss leaves Teams selected.

```text
[universal control][gap][ particle region ] [ notification area ] [ panel ][switcher]
```

## Panels

The actual layout lists `system`, `teams`, `ytmusic`, `praatvol`, `stats`, and `fan`, in that order.
The registry also contains `vscode`.
An initial selection without a valid stored identifier uses System.
A socket selection can show any registered panel, even outside the layout's panel list.
The switcher then includes the selected panel before the configured list.

| Panel | Identifier | Icon | Display and action |
|---|---|---|---|
| System | `system` | A graphite tile contains a white clock at 10:10. | Three columns show time with seconds, weekday/date, and week/battery. Taps perform no action. |
| Teams | `teams` | The Teams icon or a graphite people tile identifies the panel. | The meeting name appears above elapsed time. Two buttons toggle the microphone and camera. |
| YouTube Music | `ytmusic` | The Pear icon identifies the panel. | The panel shows cover, title, artist, progress, and previous/play/next controls. A cover or title tap opens Pear. |
| VS Code | `vscode` | The Visual Studio Code (VS Code) icon identifies the panel. | A window control cycles windows. Run sends F5; Command opens the Command Palette with ⇧⌘P. |
| praatvol | `praatvol` | A waveform tile identifies the panel in the switcher. | Room/Call buttons start capture. The panel shows recording, progress, review, and attention states. |
| Stats | `stats` | The Stats icon identifies the panel. | Four cells show processor load, memory, temperature, and network rates. A tap opens Stats. |
| Fan | `fan` | A graphite tile contains a white fan. | A mode button, history graph, and readout control the fan. Custom replaces the graph with a slider. |

System refreshes every 0.5 seconds and reads battery state every 10 seconds.
The week number follows International Organization for Standardization (ISO) 8601.
Stats refreshes every 2 seconds.
The other panels request a refresh every second while attached to the bar.

## Use the switcher

1. Tap the app icon at the right edge.
2. Tap a panel icon in the replacement row.

The selected icon uses the accent colour.
Tap the switcher cross to close the row without a selection.
The row also closes after 6 seconds.
The row scrolls horizontally if the icons exceed the available width.

## Colours

- Buttons use the neutral Touch Bar style.
  The switcher uses a borderless 36-point (pt) button with a 30 pt app icon.
- `TouchBarIcon.swift` fits symbol glyphs into an 18 pt box.
  Wide glyphs can use up to 1.4 times the box width.
  Panel icons use 24 pt before the switcher scales its icon to 30 pt.
- The Touch Bar ignores `contentTintColor`.
  State icons therefore contain the tint in the image.
- The system accent colour marks selection.
  Green, orange, and red indicate state.
- Stats load and memory rings turn orange at 70% and red at 90%.
  The Stats thermometer turns orange at 75 °C and red at 90 °C.
  Fan temperature uses the same 75 °C and 90 °C thresholds.

## Data sources

- **YouTube Music:** Pear Desktop uses bundle identifier `com.github.th-ch.youtube-music`.
  The panel reads macOS Now Playing through the private MediaRemote framework.
  The panel needs no Pear plugin or Application Programming Interface (API) server.
  Pear must run before the panel requests track metadata.
- **Play controls:** MediaRemote sends commands to the current Now Playing app, which can differ from Pear.
  Failed or unavailable MediaRemote commands fall back to media keys.
- **VS Code windows:** The Accessibility API supplies window titles and document paths.
  The title `file.swift — project` supplies the project name.
  The document path supplies the file name and project folder where available.
- **Window colours:** A stable Fowler–Noll–Vo hash (FNV-1a) selects one of eight system colours from the project folder path.
  The project name supplies the key if the document path is unavailable.
  The colours are blue, purple, pink, orange, teal, green, indigo, and yellow.
  Different projects can share a colour.
- **Window order:** The panel sorts windows by folder path.
  The window control shows a colour stripe, project, file, and one dot per window.
  The active window has a larger dot with a white ring.
  A tap first raises VS Code if another app has focus; subsequent taps cycle windows.
- **Stats:** The panel reads system counters directly rather than queries the Stats app.
  Central processing unit (CPU) load uses differences between per-core counters.
  Memory includes app, wired, and compressed memory, divided by physical memory.
  Temperature averages the performance-core and efficiency-core sensors named `pACC MTR Temp*` and `eACC MTR Temp*`.
  Network rates use byte-counter differences across all interfaces except loopback.
  The first sample lacks processor and network rates.
  The panel shows no graphics processing unit (GPU) metric.

The Stats processor cell includes a total ring and one square per core.
Efficiency cores occupy the top row; performance cores occupy the lower row.
The memory ring shows a percentage without a percent symbol.
The temperature cell uses a thermometer and a value, without a meter.
Network arrows use blue for download and green for upload.

## praatvol

The panel connects directly to praatvol, not through the MTMR socket.
Release uses `~/Library/Application Support/praatvol/control.sock`.
Dev uses `~/Library/Application Support/praatvol-dev/control.sock`.
The layout option `"praatvol":{"app":"dev"}` selects Dev; `"release"` is the default.
The actual layout selects Dev.

The protocol uses newline-delimited JavaScript Object Notation (JSON), with at most 4096 bytes before each newline.
The client opens one `subscribe` connection while the panel remains attached.
The client expects a version 1 snapshot within 3 seconds and reconnects after 2 seconds on disconnect.
The client accepts bare snapshots and wrapped `{"ok":true,"status":...}` replies.
The expected source sends snapshots on connection, on state changes, and each second during recording.
The client closes the subscription after panel detachment.

Optional progress fields can be absent or null.
Unknown step names show a spinner and the capitalised name.
The panel uses 30 pt height, 8 pt gaps, measured text, and tail truncation without a smaller font.
The waveform appears only in the switcher.

| State | Display and controls |
|---|---|
| Offline | The panel shows centred grey “praatvol offline”. |
| Idle or failed | Equal-width Room and Call buttons fill the panel. A failed run adds a red dot to Room. |
| Starting | A spinner and “Starting” appear beside Stop. One Stop tap cancels setup. |
| Recording | The first row shows a red pulse, elapsed time, and Room/Call pill. The second row shows microphone and signal dots. |
| Preparing | A spinner and label appear above a 3 pt progress line. `preparingFraction` controls the line. |
| Uploading | `uploadFraction` controls the line and percentage. |
| Transcribing | The panel estimates progress from `stepStartedAt` and `estimatedSeconds`, with a `~` prefix and a 95% cap. |
| Review | “Transcribe?” appears above duration and decimal megabytes (MB). Two 56 pt buttons offer Transcribe or Keep audio only. |
| Needs attention | An orange triangle and “Needs attention on Mac” replace the normal readout. Command buttons remain disabled. |
| Saved | A green check and “Saved” appear for the recent save interval, then idle controls return. |

Tap Stop twice within 3 seconds during recording.
The first tap shows “Stop?” and widens the button to fit the text.
The second tap sends `stop`.
Panel detachment or a state change cancels confirmation.

Preparing and uploading fractions cap at 0.99 while their steps remain active.
Missing fractions or estimates leave the progress track empty and omit the percentage.
The progress model refreshes locally each second.
An available review warning replaces duration and size with an orange triangle and the first warning.
The panel omits absent duration and size values.

The Saved interval uses `stepStartedAt` if present and lasts less than 4 seconds from that timestamp.
The timestamp check permits up to 2 seconds of future clock skew.
Without `stepStartedAt`, only a live transition to Saved starts the 4-second interval.
A first Saved snapshot without a timestamp does not flash.
Repeated snapshots do not extend the interval.

Buttons send `record-room`, `record-call`, `stop`, `transcribe`, or `keep` through separate short-lived connections.
The review checkmark sends `{"cmd":"transcribe"}`; the cross sends `{"cmd":"keep"}`.
The review commands require the source's review state.
The client uses 2-second deadlines for connection, write, and reply stages.
Commands neither retry nor change the displayed source state optimistically.
Command errors show for 2 seconds; `notReviewing` maps to “Already answered”.

Green signal dots indicate audio.
Hollow grey dots indicate silence.
Orange dots indicate more than 10 seconds of silence.
Room uses one microphone dot; Call adds a system-audio dot.

Review and extended progress use these optional fields from protocol addendum v1.1:

- `stepStartedAt` provides the step timestamp.
- `estimatedSeconds` provides the duration estimate.
- `preparingFraction` provides preparation progress.
- `durationSeconds` provides the review duration.
- `uploadBytes` provides the review size.
- `warnings` provides review warnings.

The panel also accepts older version 1 snapshots without these fields.
Review controls appear only if the source sends `review`.
Run `python3 -I tests/features/test-praatvol.py` for focused checks with a temporary fake socket.

## Teams

The actual layout declares one `teams/teams-watch` process on the `appControls` item's `watcher` field.
Set `"teams":{"directory":"${REPO}/teams"}` so the panel can execute the tap scripts.
`tbctl layout` substitutes the repository path.
The directory must be absolute and contain executable `teams-mic-tap` and `teams-camera-tap` files.
Without a directory, the readout works but the buttons remain disabled.

The watcher uses the Chrome DevTools Protocol (CDP) on `127.0.0.1:9333`.
The watcher reads `/json/version` once per connection and keeps the browser WebSocket open.
`Target.setDiscoverTargets` reports target creation, updates, and removal.
The watcher attaches to eligible Teams pages, including the main page.
`Runtime.addBinding` carries Document Object Model (DOM) snapshots from a MutationObserver.
Focus, blur, and visibility events also request snapshots.

Navigation reinstalls the observer.
The observer reads call controls, device labels, page title, and available duration text.
The watcher performs no periodic target or DOM queries.
With no pending command or delivery, the watcher blocks on the socket indefinitely.
Connection failures retry after 5, 10, and then at most 30 seconds.
A connection that lasts at least 30 seconds resets that backoff.

Changed state uses this socket message:

```json
{"cmd":"teams","online":true,"inCall":true,"title":"Weekly sync","mic":"on","camera":"off","focused":true,"joinedAt":1792400000,"durationText":"12:03"}
```

| Field | Rule |
|---|---|
| `inCall` | The field is a required boolean. |
| `online` | The optional boolean defaults to true. |
| `focused` | The optional boolean defaults to false. |
| `title` | The optional string defaults to empty. |
| `mic` | The panel accepts `on`, `muted`, or `unknown`; other strings map to unknown. |
| `camera` | The panel accepts `on`, `off`, or `unknown`; other strings map to unknown. |
| `joinedAt` | The optional number supplies epoch seconds; null means absent. |
| `durationText` | The optional string supplies `m:ss` or `h:mm:ss`; null means absent. |

Wrong types reject the message; unknown fields do not affect state.
Optional fields also accept null and use their defaults.
`{"cmd":"teams","online":false,"inCall":false}` marks the watcher offline.
Offline does not confirm call end, so restoration waits for an online no-call report.
The socket registers `teams` when an App Controls item includes the Teams panel.
`tbctl` has no `teams` subcommand.

The panel displays a 12 pt semibold meeting name above an 11 pt red elapsed timer.
Both lines align left; the title truncates with an ellipsis.
Generic or empty titles display “Meeting”.
Two bordered 76 × 30 pt buttons occupy the right side, with 8 pt gaps.
Green indicates microphone/camera on; red indicates muted/off; grey indicates unknown.
Outside a call, the panel displays “No meeting” or “Teams offline”.

The local timer updates each second.
A changed valid DOM duration synchronises the timer; otherwise `joinedAt` supplies the origin.
Without either value, the clock starts at local receipt.
The watcher records `joinedAt` when the watcher first observes that target's call.
Current target titles contain the plain meeting name.
The parser also strips the older ` | Microsoft Teams` suffix and limits names to 80 characters.

A hangup control or a recognised microphone/camera control marks a call.
A focused call takes priority if multiple call pages exist.
Meeting-window focus selects Teams once per call.
Any manual switcher or `tbctl app` selection cancels restoration and further automatic selection for that call.
Focus loss leaves Teams selected.

Tap scripts only toggle the requested device once.
The panel runs scripts asynchronously with a 6-second process timeout and no toggle retry.
Known device states change optimistically for at most 5 seconds until a watcher snapshot arrives.
Command failure logs an error and clears the optimistic state if no newer snapshot exists.
Failed state deliveries retry after 5 seconds without extra CDP queries.
“Meeting joined” notifications never retry.

Run focused fixture checks without live Teams access:

```bash
python3 -I tests/features/test-live-buttons.py
python3 -I tests/features/test-teams.py
```

Source comments retain hardware checks for duration selectors, focus events, pre-join detection, and multiple call pages.
The setup and one-shot commands appear in [runbook-teams-debug.md](runbook-teams-debug.md).
To roll back, restore the earlier sources and layout.
Rebuild the app.
Install the restored layout explicitly.
Builds and tests leave the installed `items.json` unchanged.

## Fan

The panel requires the ThermalForge root daemon and connects to `/var/run/thermalforge.sock` without elevated privileges.
ThermalForge writes the System Management Controller (SMC); `FanController` owns the curves.
The daemon protocol uses a 4-byte big-endian length followed by JSON, with one request per connection.
Requests include `v: 1` and `oneshot: false`.
The socket permits only the user who installed the daemon.

| Mode | Behaviour |
|---|---|
| Apple | MTMR sends `auto` on transition and then makes no control writes. Status reads continue. |
| Quiet | The curve starts at 70 °C and reaches 50% at 90 °C, with squared ease-in. |
| Cool | The default curve starts at 45 °C and reaches 100% at 75 °C, with squared ease-in. |
| Max | The controller requests full speed. |
| Custom | The controller requests a fixed fraction of the fan range. At 85 °C, the mode switches to Cool. |

The mode button opens a row with all five modes and closes after selection or 6 seconds.
Custom uses a slider; release commits the selected value.
The mode persists under `FanMode`; the custom fraction persists under `FanCustomPercent`.
The initial custom fraction is 0.4.

The graph retains 60 samples at 2-second intervals, with the newest sample on the right.
The graph shows temperature, actual speed as a blue area, and requested speed as a dashed blue line.
Dashed thresholds mark curve start, full speed, and the red 95 °C safety floor.
Temperature spans 30–100 °C; speed spans 0–100% of the fan range on the same height.
The readout shows temperature above revolutions per minute (rpm), or “off” at zero speed.

The controller uses the hottest `TC*`, `Tp*`, `TG*`, or `Tg*` sensor, smoothed with coefficient 0.35.
The fan returns to Apple below the curve start, with 5 °C hysteresis after the curve starts.
The controller runs every 2 seconds even if another panel appears.
Speed writes require at least 100 rpm change; decreases cap at 300 rpm per tick.
Otherwise the controller sends a heartbeat while a hold remains active.
The controller repeats a request if the daemon reports that the hold ended.

Keep the daemon safety controls active.
The daemon requests full speed at 95 °C and returns control to Apple after 15 seconds without a heartbeat.
`thermalforge auto` also returns control immediately.
A missing temperature makes MTMR request Apple control.
Custom's 85 °C transition also posts a notification.

```bash
bin/tbctl fan
bin/tbctl fan quiet
bin/tbctl fan custom --percent 30
```

`{"cmd":"fan"}` reports state.
Optional `mode` selects `apple`, `quiet`, `cool`, `max`, or `custom`.
Optional numeric `percent` sets the saved custom value from 0 through 100; `percent` alone does not select Custom.
The reply contains `fan.mode`, `fan.customPercent`, and available `temperature`, `rpm`, or `error` fields.
The socket registers `fan` after a layout includes the Fan panel.

## Layout entry

```json
{
  "type": "appControls",
  "align": "right",
  "width": 340,
  "switcher": "right",
  "panels": ["system", "teams", "ytmusic", "praatvol", "stats", "fan"],
  "watcher": ["${REPO}/teams/teams-watch"],
  "teams": {"directory": "${REPO}/teams"},
  "praatvol": {"app": "dev"}
}
```

`switcher` accepts `left` or `right`; the default is `left`.
`panels` defaults to the registry order and rejects an empty list.
The registry order is System, Teams, YouTube Music, VS Code, Stats, Fan, and praatvol.
Unknown identifiers are ignored; a list with no known identifiers uses System.

`width` sets the complete zone width, including the switcher.
The solver never shrinks right items.
At the measured host width of 1004 pt, a 340 pt zone leaves 292 pt for notifications.
The actual notification minimum is 358 pt, so MTMR logs a warning.
A zone at most 307 pt preserves that minimum with 16 pt outer padding.

## Socket commands

```bash
bin/tbctl app
bin/tbctl app stats
```

Without an identifier, `tbctl app` sends `{"cmd":"apps"}` and lists all registered panels with selection state.
With an identifier, the client sends `{"cmd":"app","id":"stats"}`.
An unknown identifier rejects the selection.
MTMR registers both commands after an App Controls item loads.

## Add a panel

Create one Swift file in `mtmr/overlay/`.
The panel must inherit `NSView` and conform to `AppControlsPanel`.
The protocol requires these members:

- `static id: String` identifies the panel uniquely.
- `static name: String` supplies the display name.
- `static icon() -> NSImage` supplies the icon.
- `init(frame: NSRect)` creates the panel.
- `refreshInterval: TimeInterval` requests a refresh interval.
- `refresh()` updates the panel.

1. Add the class to `AppControlsRegistry.panels` in `AppControlsItem.swift`.
2. Add the identifier to the layout's `panels` list.
3. Run `mtmr/build.sh`.
4. Follow the build runbook to restart MTMR and grant Accessibility access.
5. Install the changed layout with `bin/tbctl layout actual`.

Use `AppControlsStyle` for labels, buttons, colours, and row geometry.
Use `AppControlsApps` for app icons and app launches.
Use `AppControlsMeterView` for progress meters.
Keep `refresh()` fast because the zone calls `refresh()` on the main thread.
Use asynchronous work for slow sources.

Cancel action timers after panel detachment.
The zone runs periodic refreshes only while attached and enforces a minimum interval of 0.25 seconds.

## Files

| File | Contents |
|---|---|
| `mtmr/overlay/AppControlsItem.swift` | The file defines the protocol, registry, options, selection, zone, and switcher. |
| `mtmr/overlay/AppControlsKit.swift` | The file provides shared styles, app helpers, key events, and meters. |
| `mtmr/overlay/TouchBarIcon.swift` | The file provides shared icon sizes and image tints. |
| `mtmr/overlay/AppControlsSystemPanel.swift` | The file implements System. |
| `mtmr/overlay/AppControlsTeamsPanel.swift` | The file implements Teams and asynchronous tap actions. |
| `mtmr/overlay/TeamsState.swift` | The file defines Teams snapshots, geometry, clock, and automatic selection. |
| `mtmr/overlay/AppControlsMusicPanel.swift` | The file implements Now Playing and YouTube Music. |
| `mtmr/overlay/AppControlsCodePanel.swift` | The file implements VS Code. |
| `mtmr/overlay/AppControlsPraatvolPanel.swift` | The file implements praatvol controls and readouts. |
| `mtmr/overlay/PraatvolClient.swift` | The file defines the praatvol client, snapshots, and display model. |
| `mtmr/overlay/AppControlsStatsPanel.swift` | The file implements Stats and system metrics. |
| `mtmr/overlay/AppControlsFanPanel.swift` | The file implements Fan, curves, and the daemon client. |
| `mtmr/overlay/NotificationMirror.swift` | The file copies macOS notifications into the queue. |
| `mtmr/patches/0005-app-controls-watchers-welcome.patch` | The patch adds the item type, watcher supervision, mirror setup, and welcome hook. |
