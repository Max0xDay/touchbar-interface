# Layouts

The repository contains two layouts in `layouts/`.

| Layout | File | Purpose |
|---|---|---|
| Template | `layouts/template.json` | The reference contains ✕, a spacer, three shapes, a notification area, and two temporary buttons. |
| Actual | `layouts/actual.json` | The everyday bar contains universal control, a spacer, a notification area, and App Controls. |

Keep the template as a reference unless an experiment requires a change.
The template sets `maxChars: 40` and `defaultSeconds: 5`.
The actual layout sets `maxChars: 28` and `defaultSeconds: 8`.

## Switch the layout

```bash
bin/tbctl layout
bin/tbctl layout actual
bin/tbctl layout template
bin/tbctl layout actual --dry-run
```

Without a name, `tbctl layout` reports the active layout and available names.
A live file that differs from both rendered layouts reports `custom`.
The command reports `none` if the live file does not exist.

`tbctl layout NAME` performs these steps:

1. The client substitutes the repository path for `${REPO}` in `layouts/NAME.json`.
2. The client checks the rendered JavaScript Object Notation (JSON).
3. The client backs up the current `items.json` in `~/Library/Application Support/MTMR/layout-backups/`.
4. The client retains the newest 20 backups.
5. The client writes `~/Library/Application Support/MTMR/items.json` in place.
6. My TouchBar My Rules (MTMR) reloads the bar.

Use `--dry-run` to print the rendered layout without a backup or write.
The first launch of MTMR creates the support directory and the initial `items.json`.

To restore a saved layout, write the backup into the live file in place:

```bash
python3 -c 'from pathlib import Path; import sys; Path.home().joinpath("Library/Application Support/MTMR/items.json").write_bytes(Path(sys.argv[1]).read_bytes())' /path/to/items-backup.json
```

Alternatively, run `bin/tbctl layout template` to return to the reference layout.

## Universal control button

The actual layout starts with this item:

```json
{"type":"volume","align":"left","width":30,"id":"volume"}
```

A 1-point (pt) spacer follows the control.
The spacer and two 8 pt gaps leave 17 pt after the control.
The actual layout contains no separate exit item or left Teams buttons.

The control measures 30 × 30 pt and displays `slider.horizontal.3`.
The solver keeps the control width fixed.
Patch `0006-volume-button.patch` maps the `volume` type to `VolumeTouchBarItem`.
The `id` identifies the layout item; the control does not bind to live-button state.
The control accepts no feature-specific layout options.

- Tap the control to open a separate Touch Bar page.
- Tap the control on that page to return.
- Leave the page untouched for 6 seconds to return automatically.
- Hold the main-bar control for at least 0.5 seconds to return to Apple's Touch Bar.

A held touch keeps the control page open.
Slider changes and page touches reset the idle timeout.
Release after a long press does not open the control page.
Bar dismissal or recreation closes the control page without another presentation.

The control page contains these items, from left to right:

1. The same 30 × 30 pt control returns to the main bar.
2. A native `NSSliderTouchBarItem` controls brightness.
3. A native `NSSliderTouchBarItem` controls volume.
4. A flexible spacer keeps the controls at the left.

Each slider container measures 200 pt, including both accessories.
AppKit supplies the slider appearance, standard item gaps, and accessory widths.
The brightness accessories use `sun.min.fill` and `sun.max.fill`.
The volume accessories use `speaker.fill` and `speaker.wave.3.fill`.
`TouchBarIcon` renders the accessories in white with an 18 pt icon box.
The control page contains no notifications, App Controls, labels, or extra close button.

Brightness uses private `DisplayServicesGetBrightness` and `DisplayServicesSetBrightness` functions through `dlopen` and `dlsym`.
The controller prefers an online built-in display over the main external display.
The controller reads brightness on page open and once per second while the page stays open.
The controller uses IODisplay only if the DisplayServices framework or symbols are unavailable.
Operation failures log once per operation for each controller instance.
CoreDisplay brightness calls fail on the reference M1 with port lookup error 1102; see [findings.md](findings.md).

Volume uses CoreAudio controls for the default output device.
CoreAudio listeners follow keyboard changes, app changes, and output-device changes.
An output device without writable volume disables the slider.
The speaker accessory does not toggle mute.
Volume zero also sets mute if the device supports writable mute.
A positive volume value clears mute if the device supports writable mute.

Each slider ignores external refreshes during direct touch, even if the finger leaves the slider bounds.
Each value change also suppresses refreshes for 0.6 seconds.
Each slider coalesces writes independently to at most 60 hertz (Hz).
The first write occurs immediately; subsequent writes retain the latest value.
Release or page close preserves the final pending write before the controller stops.

The source retains hardware checks for external displays, unsupported output devices, long presses, and touch ownership.
Focused checks use `python3 -I tests/features/test-volume.py` without device writes.
To roll back, restore the previous sources and actual layout from version control.
Rebuild the app before an explicit layout installation.

## Charging particles

`ChargingMonitor.swift` receives I/O Kit (IOKit) power notifications without a polling timer.
An adapter transition from disconnected to connected requests one green burst.
The monitor ignores repeat connections less than 3 seconds apart.
Launch, bar open, and unplug do not request a burst.
A hidden bar skips the burst rather than queues the burst.

`ParticleFlowView.swift` clips particles between the bar's left edge and the notification area's left edge.
Before the notification frame exists, the region uses one third of the bar width.
Particles pass touches to the controls beneath the particle view.

The default burst uses 45 green dots over 2.5 seconds.
The front-loaded burst emits within the first 0.6 seconds; individual particles live for 1.2–2 seconds.
Soft acceleration, vertical wobble, glow, varied brightness, and varied endpoints shape the effect.
Particles fade and shrink within the final 30% of the region.
The whole burst also fades in and out.

After the burst, a connected adapter below full capacity enables a smaller green trickle.
The trickle emits one particle every 0.8–1.6 seconds, with at most four particles active.
Each trickle particle lasts 3.2–4.2 seconds.
Trickle particles travel three quarters of the burst distance.
The trickle stops new particles at full capacity or on unplug.
A macOS charge hold below full capacity keeps the trickle active.
Existing trickle particles complete their fades.

Bar open resumes the trickle if the power state permits the trickle, without another burst.
Bar detachment cancels particle animations and scheduled work.

Preview commands use the same region:

```bash
bin/tbctl particles
bin/tbctl particles --count 25 --seconds 4 --color '#34C759' --style sparks
bin/tbctl particles --trickle on
bin/tbctl particles --trickle off
```

| Option | Behaviour |
|---|---|
| `--count` | The burst accepts an integer from 1 through 200; the runtime default is 45. |
| `--seconds` | The burst accepts a finite duration from 0.5 through 10 seconds; the runtime default is 2.5. |
| `--color` | The burst accepts `#rrggbb`; the default is `#34C759`. |
| `--style` | The burst accepts `dots` or `sparks`; the default is `dots`. |
| `--trickle on` | The preview forces the trickle on, independent of power state. |
| `--trickle off` | The preview releases the override and restores real charging state. |
| `--usb` | The preview requests the fixed blue accessory preset described below. |

`--usb` and `--trickle` are mutually exclusive.
The client ignores burst overrides if either preset option appears.
Current `--help` text still lists defaults 30 and 5.5; `ParticleFlowView` and the socket actually use 45 and 2.5.
A new charging burst replaces the previous charging burst and resumes the trickle afterward if enabled.

The socket accepts these equivalent messages:

```json
{"cmd":"particles"}
{"cmd":"particles","count":25,"seconds":4,"color":"#34C759","style":"sparks"}
{"cmd":"particles","trickle":true}
{"cmd":"particles","trickle":false}
{"cmd":"particles","preset":"usb"}
```

The socket prioritises `preset`, then `trickle`, then burst fields.
The only supported preset is `usb`.
A success reply confirms command acceptance, not visible playback on a hidden bar.
Source comments retain checks for hidden-bar detection and touch delivery on hardware.

### USB plug-in animation

`USBDeviceMonitor.swift` receives Universal Serial Bus (USB) device matches for `IOUSBHostDevice` through IOKit.
An eligible external device connection requests 20 blue sparks over 2.5 seconds.
External display additions also request the same effect through a CoreGraphics callback.
New USB-C accessory transports request the same effect through IOKit first-match notifications.
The monitor watches `IOPortTransportStateDisplayPort` and `IOPortTransportStateCIO`.
These transports trigger sparks even without a USB device or a new display.
The monitor ignores the USB2 and USB3 transports because Apple chargers also publish them.
Real USB data devices still trigger sparks through `IOUSBHostDevice`.
The sparks start at once, but skip if a charger connected within the last 3 seconds.
A charger burst that starts during the sparks fades the sparks out within 0.25 seconds.
A charger plugged in through an adapter therefore shows only the green charging burst.
The monitor records online displays at startup and ignores built-in displays and already-connected display identifiers.
Display events require an add flag outside the configuration-begin phase; mirror-only changes do not trigger sparks.
The same display identifier also has a 5-second reconnect debounce.

The preset uses colour `#0A84FF` and the same left region as charging particles.
A shared global 2-second debounce suppresses closely spaced eligible USB device, display, or USB-C transport connections.
The monitor drains each startup USB device and transport iterator without animation.

The monitor excludes these devices:

- The monitor excludes built-in devices and devices marked internal or non-removable.
- The monitor excludes descendants of internal USB devices or ports.
- The monitor excludes hubs with device class 9.
- The monitor excludes billboard-only devices with device class 17.

The ancestor check stops at the USB controller.
An external hub's eligible peripherals can trigger sparks.
A hidden bar skips sparks.
A new USB burst replaces the previous USB burst without interrupting a charging burst or trickle.
The source retains hardware checks for internal markers, power-only adapters, docks, display-only connections, mirroring, and sleep/wake.
It also flags transport re-publication on repeated attaches and CC-only charger behaviour across Mac models for hardware verification.

```bash
bin/tbctl particles --usb
```

To remove automatic particle effects, restore the earlier sources.
Rebuild the app afterward.
Particle effects require no layout options.

## Welcome notification

The notification item accepts `"welcome": "text"`.
MTMR requests the welcome notification on these transitions:

- MTMR requests the notification at launch.
- MTMR requests the notification after a layout load.
- MTMR requests the notification on return from Apple's Touch Bar.

The queue suppresses a duplicate welcome text while the same text remains live.
Neither repository layout sets `welcome`.

## Notifications from other apps

The notification item accepts a `mirror` object:

```json
"mirror": {
  "stickyApps": ["com.microsoft.teams2", "com.microsoft.outlook"],
  "stickySeconds": 600,
  "lobApps": ["net.kovidgoyal.kitty"],
  "ignoreApps": []
}
```

The actual layout enables the mirror with these sticky apps and kitty mapping.
The template leaves the mirror disabled.

- `stickyApps` extends entry lifetime to `stickySeconds`, which defaults to 600 seconds.
  Each display still lasts at most 8 seconds.
- `lobApps` replaces the sender icon with the lob icon.
  The heading is always `lob`.
  A body that contains “waiting for your input” becomes “lob is awaiting response”.
  Other bodies keep their text.
- `ignoreApps` excludes listed apps from the mirror.
- The mirror compares app identifiers without letter case.
- `stickySeconds` must be finite, positive, and at most 86400 seconds.

The mirror reads the Notification Center database once per second through a read-only connection.
The path is `$(getconf DARWIN_USER_DIR)com.apple.notificationcenter/db2/db`.
The reference macOS version permits access without Full Disk Access.
The mirror starts near the current delivery time and skips the full notification history.
The mirror joins a title and subtitle with ` · `.
A title and body produce two lines; either field alone produces one line.

## Notification queue

- A new notification appears immediately for at most 8 seconds or its remaining lifetime, whichever is shorter.
- Each entry has an independent lifetime.
  A long-lived entry does not block a newer entry.
- After the display deadline, the area fades to empty while live entries remain hidden.
  Expiry does not automatically reveal another hidden entry.
- A dim, steady 5 pt dot marks hidden live entries in the empty area.
  Tap the area to recall the newest hidden entry for at most 8 seconds.
  Recall preserves the remaining lifetime.
- Swipe left for the next live entry.
  Swipe right for the previous live entry.
  Navigation wraps in both directions and starts a fresh display deadline.
- A touch pauses all lifetime and display deadlines until release or cancellation.
- A pulsing 4 pt dot appears at the top right if multiple entries remain live during a visible notification.
- The queue accepts at most 256 entries.
  A full queue rejects another socket notification.
- Lifetime expiry removes an entry.
  `bin/tbctl clear` removes all entries immediately.
  Dismissal in macOS leaves the bar entry unchanged.

`bin/tbctl notify "text" --seconds 3` gives the entry a 3-second lifetime.
The entry leaves no unread dot after that lifetime expires.
An omitted `--seconds` uses the layout's `defaultSeconds`.
`--seconds` must be finite, positive, and at most 86400.

## Two-line notifications from scripts

```bash
bin/tbctl notify "Weekly sync" --title "Meeting joined" --app com.microsoft.teams2
```

`--title` adds a 12 pt semibold heading above the 10 pt grey body.
Without a heading, the area uses centred 15 pt monospaced text.
`--app` selects the icon through the app's bundle identifier.
The icon measures 30 pt, matching the switcher icon.
The text layout reserves an 18 pt icon slot and a 6 pt gap.

`teams/teams-watch` sends “Meeting joined” when the watcher first observes a call, including startup during a call.
The entry has a 15-second lifetime but an 8-second display limit.
The body contains the meeting name.
Current call targets use the plain meeting name; the title parser also accepts the older ` | Microsoft Teams` suffix.
`teams/teams-mute meeting` prints the parsed name.
