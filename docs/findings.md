# Findings

This document records platform facts and source evidence.
The reference machine is a 13-inch MacBook Pro, M1, 2020, with macOS 14.7.6 and a Touch Bar.

- **Verified** identifies an observation on the reference machine.
- **Source** identifies behaviour present in repository code.
- **Unverified** identifies a remaining hardware check, not an established fact.

## 1. MTMR (My TouchBar My Rules)

The upstream repository is [My TouchBar My Rules (MTMR)](https://github.com/Toxblh/MTMR), under the MIT License.

- The last release, v0.27.0 from 2020, and the Homebrew cask use Intel binaries that require Rosetta 2. **Verified.**
- Upstream commit `94fc98c` adds arm64 support.
  `mtmr/build.sh` pins the full hash `94fc98cceff94cf69a2e7c28f726cf35ab93c461`. **Source.**
- The build rejects non-arm64 execution, Rosetta translation, a different upstream commit, or upstream changes. **Source.**
- MTMR watches `~/Library/Application Support/MTMR/items.json` through a file descriptor.
  An in-place write triggers a reload; an atomic replacement breaks the watcher until restart. **Verified.**
- A configuration reload recreates the bar and causes visible flicker.
  Socket state updates avoid that reload. **Verified.**
- The upstream app has no socket; `NotificationSocketServer.swift` adds the local push interface. **Source.**
- General item fields include `width`, `align`, `bordered`, `background`, `title`, `image`, `matchAppId`, and `actions`.
  The `group` type opens a sub-bar. **Source.**
- App activation can construct item instances that never attach to a window.
  View timers start after attachment. **Source.**
- Patch 0005 presents the notification bar only after an item change or if the bar was hidden.
  Some app switches still produce a brief flicker; the underlying cause remains unverified. **Verified.**
- The template's `exitTouchbar` item minimises the custom bar.
  The actual layout instead uses a universal-control long press.
  The MTMR icon on Apple's bar restores the custom bar. **Source; exit behaviour verified.**
- The Do Not Disturb item fails on macOS 14.7.6. **Verified.**

## 2. Touch Bar facts

- The custom bar owns the full host width if `showControlStrip` remains unset. **Verified.**
- The host measures **1004 × 30 points (pt)**.
  The container's 1085 pt constant is only a fallback before usable bounds exist. **Verified from logs; Source.**
- A 340 pt App Controls zone leaves 292 pt for notifications at that host width.
  The actual minimum (`maxChars: 28`) is 284 pt; a zone at most 344 pt avoids the minimum-width warning. **Source.**
- The Touch Bar ignores `contentTintColor` for these controls.
  `TouchBarIcon` embeds explicit tints in images. **Verified.**
- A view at zero alpha can still intercept touches.
  `NotificationLayoutView` sets `isHidden` after fade-out. **Verified.**
- Notification touches report horizontal movement but no vertical movement. **Verified.**
- Universal control uses native `NSSliderTouchBarItem` containers, each 200 pt wide including accessories. **Source: `VolumeControl.swift`.**
- The control suppresses refreshes during direct touch and for 0.6 seconds after a value change.
  Each slider limits writes to 60 hertz (Hz). **Source: `UniversalSliderState`.**

## 3. Native build with the Command Line Tools

- The Command Line Tools software development kit (SDK) contains stubs for `DFRFoundation`, `MultitouchSupport`, `CoreBrightness`, and `CoreDisplay`. **Verified.**
- The build links those private frameworks and targets macOS 11. **Source.**
- The storyboard contains only the main menu; the native entry point replaces the storyboard.
  The build therefore needs neither `ibtool` nor full Xcode. **Source.**
- The build copies 12 asset images as Portable Network Graphics (PNG) files.
  `BundledImage.swift` replaces asset literals, so the build needs no `actool`. **Source.**
- Patch 0001 removes Sparkle and its update menu entry. **Source.**
- The deployment target excludes newer Application Programming Interfaces (APIs) such as `systemCyan` and `kIOMainPortDefault`. **Verified.**
- Ad-hoc signatures change after rebuilds, so Accessibility access requires a reset and a new grant. **Verified.**
- A stale grant produces `Failed to match existing code requirement` in Transparency, Consent, and Control (TCC) logs.
  The Visual Studio Code (VS Code) panel can then show “No windows”. **Verified.**

### Display brightness

- CoreDisplay's `CoreDisplay_Display_*` brightness functions fail on M1 with macOS 14.7.6, with port lookup error 1102.
  Repeated calls also emitted stack traces and caused lag. **Verified.**
- `DisplayBrightnessController.swift` loads private DisplayServices functions through `dlopen` and `dlsym`.
  `DisplayServicesGetBrightness` and `DisplayServicesSetBrightness` work on the reference machine. **Verified; Source.**
- The controller prefers an online built-in display and reads once per second only while the control page remains open. **Source.**
- The IODisplay fallback applies only if the DisplayServices framework or symbols are unavailable.
  A DisplayServices operation failure does not select the fallback. **Source.**

### USB-C accessories

- A display adapter with power delivery and USB ports can attach without any `IOUSBHostDevice` or new display.
  The kernel publishes `IOPortTransportStateDisplayPort` under the `Port-USB-C@N` service instead. **Verified.**
- Apple's 35 W USB-C charger publishes `IOPortTransportStateUSB2` and `IOPortTransportStateUSB3` about 0.6 seconds after the power-adapter event. **Verified.**

## 4. Data sources for App Controls

- Pear Desktop uses bundle identifier `com.github.th-ch.youtube-music`.
  Private MediaRemote supplies title, artist, artwork, duration, elapsed time, and play state without entitlements on macOS 14.7.6. **Verified.**
- The Stats panel reads central processing unit (CPU) temperature through the private IOHIDEventSystem Application Programming Interface (API), without elevated privileges.
  Sensor names begin with `pACC MTR Temp` or `eACC MTR Temp`. **Verified.**
- The IOHIDEventSystemClient must outlive the sensor services.
  A premature client release caused a startup crash. **Verified.**
- Accessibility supplies VS Code window titles and `kAXDocument` file Uniform Resource Locators (URLs). **Verified.**
- The Notification Center database permits reads without Full Disk Access on the reference system.
  The path is `$(getconf DARWIN_USER_DIR)com.apple.notificationcenter/db2/db`. **Verified.**
- Notification payloads use binary property lists with `req.titl`, `req.subt`, and `req.body`.
  The database reuses `rec_id`, so the mirror tracks delivery time and a universally unique identifier (UUID). **Verified; Source.**
- Mac dismissal removes the database record but leaves the copied bar entry until lifetime expiry or `clear`. **Source.**
- The queue separates lifetime from an 8-second display deadline.
  Display expiry leaves an unread dot and requires arrival, swipe, or recall to reveal another entry. **Source.**
- The praatvol panel subscribes directly to the Dev or release control socket.
  The client accepts version 1 snapshots with optional review and progress fields. **Source.**
- Saved feedback uses `stepStartedAt` if available, so old Saved snapshots do not replay a recent-save interval. **Source.**

## 4a. Fans and ThermalForge

- The reference machine has one fan with a reported range of 1199–7199 revolutions per minute (rpm). **Verified.**
- Apple control can leave the fan at zero under light load with CPU sensors at 50–60 °C. **Verified.**
- ThermalForge's command-line interface (CLI) builds with Command Line Tools at commit `42bb534`.
  The Homebrew build on the reference macOS version required full Xcode. **Verified.**
- The daemon resides at `/usr/local/bin/thermalforge` with LaunchDaemon label `com.thermalforge.daemon`.
  `/var/run/thermalforge.sock` belongs to the installer's user identifier (UID) with permissions 0600. **Verified.**
- The daemon accepts `set`, `setfan`, `max`, `auto`, `status`, `state`, `heartbeat`, and `version`.
  Profiles belong to ThermalForge's app, not the daemon. **Source.**
- MTMR supplies curves in `FanController`, with a 2-second tick and smoothed peak temperature. **Source.**
- The daemon requests full speed at 95 °C on the hottest CPU or graphics processing unit (GPU) sensor.
  A supervised hold expires after 15 seconds without heartbeat. **Source.**
- Avoid an unsupervised `thermalforge set` request; the heartbeat watchdog does not revert that request. **Source.**
- The daemon limits writes to a burst of 20 and a sustained rate of 10 per second.
  `auto` is exempt. **Source.**
- A template fan symbol appeared black after switcher redraw.
  Explicit image tint fixed the icon. **Verified.**

## 4b. kitty notifications from tmux

- tmux 3.7c drops Operating System Command (OSC) 99 unless pane option `allow-passthrough` is enabled. **Verified.**
- `set -gw allow-passthrough on` sets the pane option; `set -g` alone does not. **Verified.**
- tmux passthrough wraps OSC in `ESC P tmux; <OSC with every ESC doubled> ESC \\`. **Verified.**
- OSC 99 field `d=0` means more parts follow.
  kitty waits for a part without `d=0` before display. **Verified.**
- kitty can store a single-space body.
  The mirror trims the fields so these notifications use one line. **Verified; Source.**
- macOS can defer notifications during meetings, screen shares, or Focus. **Verified.**

## 5. Microsoft Teams

- The supported third-party API is unavailable on the reference installation.
  The debug port exposes broad local control and can conflict with organisational policy. **Verified.**
- `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--remote-debugging-port=9333 --remote-allow-origins=*"` enables the debug port at Teams launch. **Verified.**
- The reference listener binds to `127.0.0.1:9333`.
  The LaunchAgent wraps `launchctl setenv` in `sh -c`; a shell's `launchctl getenv` result can remain empty. **Verified.**
- The microphone selector matches `[aria-label*="mic" i]` plus a label that starts with Mute or Unmute.
  “Unmute mic” means muted; “Mute mic” means unmuted. **Verified; Source.**
- The label prefix prevents false matches on “Microsoft…” outside calls. **Verified.**
- “Turn camera on” means camera off; “Turn camera off” means camera on.
  Document Object Model (DOM) `.click()` toggles controls without a focus change. **Verified.**
- Current call targets use the plain meeting name.
  `meeting_title()` also strips the older ` | Microsoft Teams` suffix and excludes generic titles. **Verified; Source.**
- One `teams-watch` process uses browser Chrome DevTools Protocol (CDP) events through `Target.setDiscoverTargets`.
  `Runtime.addBinding` receives MutationObserver snapshots plus focus and visibility changes. **Source.**
- Target title updates can arrive through `Target.targetInfoChanged`; the watcher republishes state after those events. **Source; fixture-covered.**
- With no pending request or delivery, `select` blocks without a timeout.
  The watcher performs no target-list or DOM polling. **Source; fixture-covered.**
- A prior idle-port trace produced one no-call snapshot, then no further CDP requests after observer setup.
  Sampled process CPU use remained 0.0%. **Verified.**
- The watcher treats a hangup control or recognised device control as an active call.
  Closing a meeting window alone can leave a call active. **Source; window behaviour verified.**
- The duration selectors, pre-join detection, focus events, and multiple-call preference retain explicit hardware checks in source. **Unverified coverage.**

### Power and USB effects

- I/O Kit (IOKit) power notifications trigger the adapter burst and charging-state changes without a polling timer. **Source.**
- Burst debounce is 3 seconds; trickle requires adapter power, active charging, and capacity below maximum. **Source.**
- The burst now defaults to 45 dots over 2.5 seconds.
  Trickle intervals span 0.8–1.6 seconds, with at most four particles active. **Source.**
- The client help still lists burst defaults 30 and 5.5; the runtime defaults differ. **Source.**
- Universal Serial Bus (USB) matches use `IOUSBHostDevice` and ignore startup matches. **Source.**
- External display additions use a CoreGraphics callback and the same blue sparks preset.
  Startup displays, built-in displays, and already-connected identifiers do not trigger sparks. **Source.**
- USB and display events share a 2-second debounce.
  Each display identifier also has a 5-second reconnect debounce. **Source.**
- The USB filter excludes internal devices, internal descendants, hubs, and billboard-only devices.
  The ancestor walk stops at the USB controller. **Source.**
- Internal markers, power-only adapters, docks, display-only connections, mirroring, and sleep/wake retain hardware verification notes. **Unverified coverage.**

## 6. Outlook

- Outlook reminders appear in an app window rather than as macOS notifications.
  Those reminders never reach the Notification Center database on the reference installation. **Verified.**
- The Outlook menu bar extra exposes countdown text such as “8m: <title>” or “Now: <title>” through Accessibility. **Verified.**
- The current code does not read Outlook reminders, the Teams calendar, or calendar subscription links. **Source.**
