# App Controls

App Controls is the zone on the right end of the bar. The zone shows one **panel** at a time. A panel is a small control surface for one app or topic, for example YouTube Music or Stats.

The user picks the panel. The panel does not follow the frontmost app. The choice stays the same after a restart or a layout reload.

```
[✕][gap][ left buttons ] |  [ notification area ]  | [SW][ panel ............................ ]
                                                      └─ switcher button: icon of the current panel
```

## Panels

| Panel | ID | Icon | Contents | Tap |
|---|---|---|---|---|
| System | `system` | "SY" badge | Large time, date, and one bullet line: ISO week and battery level. | Nothing |
| YouTube Music | `ytmusic` | Pear app icon | Cover, title, artist, a thin progress line, and the previous / play-pause / next buttons. | Cover or title: brings Pear to the front, or opens Pear if it does not run. |
| VS Code | `vscode` | VS Code icon | One chip for each open window (project name). The focused window has the accent colour. A command button (⌘) is on the right. | Chip: raises that window. Command button: opens the Command Palette (⇧⌘P). |
| Stats | `stats` | Stats app icon | CPU %, RAM %, and CPU temperature, each with a meter. | Opens the Stats app. |

If no panel is selected, App Controls shows the System panel.

## Use the switcher

1. Tap the switcher button (the icon on the left of the zone).
2. A row of panel icons replaces the panel. The current panel has the accent colour.
3. Tap a panel icon to select that panel.

To close the row without a change, tap the switcher button (✕) again. The row closes by itself after 6 seconds.

## Colours

- All buttons use the standard grey Touch Bar style.
- The system accent colour marks the selected item.
- Green, orange, and red show state only. For example, a meter turns orange above 70 % and red above 90 %. The temperature meter turns orange at 80 °C and red at 92 °C.

## Data sources

- **YouTube Music:** the player is Pear Desktop (bundle ID `com.github.th-ch.youtube-music`). The panel reads macOS Now Playing through the private MediaRemote framework. Pear publishes title, artist, cover, and play state there. The panel needs no Pear plugin. The Pear API Server plugin stays off.
- **Play controls:** the buttons send commands to the Now Playing app. If a different app plays media at that time, the buttons control that app. If MediaRemote is not available, the buttons send the media keys.
- **VS Code windows:** the panel reads window titles through the Accessibility API. MTMR already has the Accessibility permission. A title such as "file.swift — project" shows as "project".
- **Stats:** the Stats app has no Application Programming Interface (API). The panel reads the same data directly:
  - CPU: the load of all cores between two refreshes.
  - RAM: app memory, wired memory, and compressed memory, divided by the physical memory. Activity Monitor calls this value "Memory Used".
  - Temperature: the mean of the performance-core and efficiency-core sensors (`pACC` / `eACC`). These are the same sensors that the Stats app uses on M1.

## Layout entry

```json
{
  "type": "appControls",
  "align": "right",
  "width": 340,
  "panels": ["system", "ytmusic", "vscode", "stats"]
}
```

- `panels` is optional. The list sets the order in the switcher. An unknown ID makes MTMR reject the layout.
- `width` sets the width of the zone. The solver never shrinks right-hand items. Keep the width at or below `(1085 − notification minWidth − 2 × 16) / 2`. With `maxChars: 36`, the limit is 347.

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
| `mtmr/overlay/AppControlsKit.swift` | Shared style, app helpers, meter view, text badge |
| `mtmr/overlay/AppControlsSystemPanel.swift` | System panel |
| `mtmr/overlay/AppControlsMusicPanel.swift` | `NowPlaying` (MediaRemote) and the YouTube Music panel |
| `mtmr/overlay/AppControlsCodePanel.swift` | VS Code panel |
| `mtmr/overlay/AppControlsStatsPanel.swift` | Stats panel, `SystemMetrics`, temperature sensors |
| `mtmr/patches/0005-app-controls-watchers-welcome.patch` | `appControls` item type, watchers, welcome notification |
