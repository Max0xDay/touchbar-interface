# App Controls

App Controls is the zone on the right end of the bar. The zone shows one **panel** at a time. A panel is a small control surface for one app or topic, for example YouTube Music or Stats.

The user picks the panel. The panel does not follow the frontmost app. The choice stays the same after a restart or a layout reload.

```
[✕][gap][ left buttons ] |  [ notification area ]  | [ panel ............................ ][SW]
                                                        switcher button: icon of the current panel ─┘
```

## Panels

| Panel | ID | Icon | Contents | Tap |
|---|---|---|---|---|
| System | `system` | Clock tile (graphite tile, white clock at 10:10) | Three columns: time with seconds, weekday over date, and a bullet list with the ISO week and battery level. | Nothing |
| YouTube Music | `ytmusic` | Pear app icon | Cover, title, artist, a thin progress line, and the previous / play-pause / next buttons. | Cover or title: brings Pear to the front, or opens Pear if it does not run. |
| VS Code | `vscode` | VS Code icon | A window toggle, a Run button (▶), and a command button (⌘). The window toggle shows the current window in the colour of that window: a colour stripe, the project name, the open file, and one coloured dot for each window. The current window has the large dot with a white ring. | Window toggle: goes to the next window. If VS Code is not in front, the first tap brings the current window to the front. Run: presses F5 (Run > Start Debugging). Command button: opens the Command Palette (⇧⌘P). |
| Stats | `stats` | Stats app icon | Four cells: CPU (a ring with the total and a heat grid with one square for each core: efficiency cores on top, performance cores below), MEM (a ring with the %), TEMP (a thermometer and the CPU temperature), and NET (download and upload rate). | Opens the Stats app. |
| lob | `lob` | Terminal tile (orange ">_" on black) | One pill for each lob session: a blue spinner while Claude works, a slow purple arc while pi-delegate runs, a pulsing green dot when Claude finishes and waits for a reply, a grey dot when idle. Always a two-row grid with the same cell size as 4 sessions: 3 sessions leave the top-left cell empty, 1 to 2 stack in the left column, 5 or more add columns. | Nothing |
| Fan | `fan` | Fan tile (graphite tile, white fan) | A mode button (Apple, Quiet, Cool, Max, Custom); a graph of the last 2 minutes: the temperature line, the actual fan speed (blue area), the speed the mode asks for (dashed blue), and dashed lines at the mode's thresholds (fan on, full speed) and at the 95 °C floor (red); the temperature over the fan RPM. Temperature uses 30–100 °C and fan speed 0–100 % of the same height. In Custom, the graph is replaced by a slider. | Mode button: next mode. Custom: touch or drag the slider to set the fan speed. |

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
- **Window colours:** the colour key is the project folder path. The panel takes the path of the open document up to the folder with the project name, for example `/Users/maxday/Workspace/projects/maxlaptopmtmr`. If the window has no document, the key is the project name. A stable hash of the key selects one of eight system colours (blue, purple, pink, orange, teal, green, indigo, yellow). Red is not in the list, because red means "muted" or "problem" on this bar. The colour of a window stays the same when you change files and after a restart. Two projects can get the same colour.
- **Window order:** the panel sorts the windows by folder path, so the order stays the same when the focus changes.
- **Stats:** the Stats app has no Application Programming Interface (API). The panel reads the same data directly:
  - CPU: the load of all cores between two refreshes.
  - RAM: app memory, wired memory, and compressed memory, divided by the physical memory. Activity Monitor calls this value "Memory Used".
  - Temperature: the mean of the performance-core and efficiency-core sensors (`pACC` / `eACC`). These are the same sensors that the Stats app uses on M1.
  - GPU: "Device Utilization %" of the graphics accelerator (IOAccelerator).
  - NET: the byte counters of all network interfaces except loopback, between two refreshes.

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
  "panels": ["system", "lob", "ytmusic", "vscode", "stats", "fan"]
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
- Start no timers in the panel. The zone calls `refresh()` only while the panel is on the bar.

## Files

| File | Contents |
|---|---|
| `mtmr/overlay/AppControlsItem.swift` | Panel protocol, registry, selection, zone view, switcher |
| `mtmr/overlay/AppControlsKit.swift` | Shared style, app helpers, key presses, meter view, text badge |
| `mtmr/overlay/TouchBarIcon.swift` | One icon size for the whole bar; colour drawn into the icon |
| `mtmr/overlay/AppControlsSystemPanel.swift` | System panel |
| `mtmr/overlay/AppControlsMusicPanel.swift` | `NowPlaying` (MediaRemote) and the YouTube Music panel |
| `mtmr/overlay/AppControlsCodePanel.swift` | VS Code panel |
| `mtmr/overlay/AppControlsStatsPanel.swift` | Stats panel, `SystemMetrics`, temperature sensors |
| `mtmr/overlay/AppControlsLobPanel.swift` | lob panel, `LobMonitor`, session chips, lob icon |
| `mtmr/overlay/AppControlsFanPanel.swift` | Fan panel, `FanController` (curves), `ThermalForgeClient` (daemon socket) |
| `mtmr/overlay/NotificationMirror.swift` | Mirror of macOS notifications into the notification area |
| `mtmr/patches/0005-app-controls-watchers-welcome.patch` | `appControls` item type, watchers, welcome notification |
