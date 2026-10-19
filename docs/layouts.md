# Layouts

The repository has two layouts in `layouts/`:

| Layout | File | Purpose |
|---|---|---|
| Template | `layouts/template.json` | Reference for spacing and look: ✕, gap, three shape placeholders, notification area, two temporary buttons. Change the template only for a deliberate experiment. |
| Actual | `layouts/actual.json` | The everyday bar: universal control, gap, Teams mic and camera, notification area, App Controls ([app-controls.md](app-controls.md)). |

## Switch the layout

```bash
bin/tbctl layout              # show the active layout
bin/tbctl layout actual       # switch to the everyday bar
bin/tbctl layout template     # switch to the reference layout
bin/tbctl layout actual --dry-run   # print the rendered file, change nothing
```

`tbctl layout NAME` does these steps:

1. It replaces `${REPO}` in `layouts/NAME.json` with the path of this repository.
2. It copies the current `items.json` to `~/Library/Application Support/MTMR/layout-backups/`. It keeps the newest 20 copies.
3. It writes the new content into `items.json` in place. MTMR reloads the bar at once.

Rollback: run `bin/tbctl layout template`, or copy a file from `layout-backups/` back to `items.json`.

## Universal control button

The actual layout starts with `{ "type": "volume", "align": "left", "width": 30, "id": "volume" }`, followed by the existing spacer (preserving the doubled gap), then Teams mic and camera. The always-visible 30 × 30 button shows a white sliders glyph and does not shrink. The `volume` item type is retained for compatibility with patch 0006; it now replaces both the old exit button and the separate volume button.

- Tap replaces the main bar with a separate full-width control page using MTMR's group-style modal presentation. No notifications, App Controls, extra buttons or close glyph appear on this page.
- Left to right: the same 30 × 30 media button, brightness slider, volume slider. Both sliders are plain AppKit `NSSliderTouchBarItem`s with no custom cells or drawing, no labels, and standard item spacing. Each slider is 200 pt total, including both accessories, enforced by a required width on the native item container. A trailing flexible spacer keeps the controls left-aligned and the rest of the page empty. Their SF Symbol accessories are `sun.min.fill` / `sun.max.fill` and `speaker.fill` / `speaker.wave.3.fill`, rendered white through `TouchBarIcon` in the bar's 18 pt icon box, with default accessory widths.
- Drag brightness to change the built-in display through `DisplayServicesGetBrightness` / `DisplayServicesSetBrightness` (runtime-loaded with `dlopen` / `dlsym`, no extra linking). The controller prefers the online built-in display over the main external display. IODisplay is used only if the DisplayServices framework/symbols are unavailable; failures are logged once per operation, not per event. It reads on opening and refreshes every second while open to follow keyboard brightness changes; setting brightness does not trigger a refresh.
- Drag volume to change the default output device live. CoreAudio listeners follow keyboard/app changes and output-device switching. Devices without writable volume show a disabled slider. The speaker accessory is not a mute button.
- Each slider ignores external value refreshes while its finger is down (even outside its bounds) and for 0.6 seconds after its last user change. Brightness and volume writes are independently coalesced to at most 60 Hz: the first change is immediate, subsequent changes keep the latest value, and release/close preserves the final pending write, applied within the next write interval before stopping the controller.
- Tap the media button again or leave the page untouched for 6 seconds to return to the main bar. Slider changes and page touches restart the timeout; a held touch keeps the page open. Dismissing or recreating the bar closes the page and stops its controllers without reopening it.
- Hold the main-bar universal button for at least 0.5 seconds to return to Apple's Touch Bar, using the same exit routine as the former ✕ item. A short tap never exits, and releasing after a hold does not open the page.

`type`, `align` and `width` use standard item fields; `id` is optional layout identity, not a socket-driven live button. There are no control-specific options. Hardware verification is still needed for brightness with external monitors, direct touch/hold handling, modal visibility detection and the media button's left position. The focused volume tests verify 200 pt native container widths and slider ownership/coalescing without changing hardware settings. AppKit supplies the slider appearance. Rollback: restore the previous control source files and actual layout from git or the pre-change backup, rebuild, then explicitly install the restored layout with `bin/tbctl layout actual`; the template is unchanged.

## Charging particles

Connecting the power adapter plays a relaxed, touch-through green particle flow, clipped between the bar's left edge and the notification area's left edge (one third of the bar if that edge is not yet laid out). Power-source notifications trigger only a disconnected → connected transition, ignoring repeat connections within 3 seconds; opening the bar, launching MTMR already plugged in, and unplugging do not trigger it. Connections while the bar is hidden are skipped, not queued. The default 30 dots spawn over 3.5 seconds, live for 2–3 seconds, and finish within 5.5 seconds, with soft acceleration, gentle vertical wobble, subtle glow and varied brightness. They fade and shrink at varied endpoints in the region's final 30%, with an overall fade-in/out. Preview the same effect using `bin/tbctl particles` or `{"cmd":"particles"}` over the socket. Overrides remain available: `--count` (1–200, default 30), `--seconds` (total effect duration, 0.5–10, default 5.5), `--color` (`#rrggbb`, default `#34C759`), and `--style` (`dots` default, or `sparks` for streaks); for example, `bin/tbctl particles --style sparks --count 25`. The overlay never takes touches, removes itself after the effect, and stops when the bar detaches. Rendering, hidden-bar detection and touch-through need verification on hardware. To roll back, restore the particle-change source backup and rebuild; no layout changes are needed.

## Welcome notification

The notification item accepts `"welcome": "text"`. MTMR shows the text as a notification each time our bar comes on screen:

- when MTMR starts,
- when a layout loads,
- when the bar returns from Apple's bar.

Neither layout uses a welcome text now (removed 2026-10-07).

## Notifications from other apps

The notification item accepts a `mirror` object. With `mirror`, MTMR shows every macOS notification in the notification area, with the icon of the app that sent it.

```json
"mirror": {
  "stickyApps": ["com.microsoft.teams2", "com.microsoft.outlook"],
  "stickySeconds": 600,
  "lobApps": ["net.kovidgoyal.kitty"],
  "ignoreApps": []
}
```

- `stickyApps`: notifications from these apps remain live for `stickySeconds` (default 600 = 10 minutes), but each showing lasts at most 8 seconds. Other notifications remain live for `defaultSeconds`.
- `lobApps`: notifications from these apps show the lob icon. lob sessions send their notifications through kitty. Claude's notification does not say which session sent it, so the mirror credits the lob session that most recently stopped working (the green pill): the heading is that session's folder (the working directory of its Claude process), and "Claude is waiting for your input" becomes "lob is awaiting response". With no finished session the notification stays as Claude sent it. Two sessions that finish close together can be mixed up.
- `ignoreApps`: MTMR does not show notifications from these apps.
- If a notification has a title and a body, the bar shows two lines: the title as a heading, and the body smaller below. If it has only one of them, the bar shows one line.
- Source: the Notification Center database (`$(getconf DARWIN_USER_DIR)com.apple.notificationcenter/db2/db`). MTMR reads the database once a second, read-only. On macOS 14.7.6, the read needs no Full Disk Access.

## Notification queue

- A new notification shows at once, for at most 8 seconds or its remaining lifetime, whichever is shorter.
- Each notification counts down on its own. A 10-minute notification never holds back a newer one.
- After its display countdown ends, the notification fades out and the area goes empty. It remains live/unread until its own lifetime ends.
- While the area is empty and live notifications remain, a dim, non-pulsing 5 pt dot shows in the centre. Tap anywhere in the area to recall the newest hidden notification for up to 8 seconds without resetting its lifetime.
- Swipe left or right to move through all live notifications; each showing starts a fresh display countdown of up to 8 seconds. A touch on the area pauses both display and lifetime countdowns.
- While a notification is visible and more than one notification is live, a small pulsing dot shows at the top right of the area.
- Notifications are removed only when their lifetime countdown ends. With no live notifications, the unread dot disappears. A `tbctl notify` with `--seconds 3` expires after 3 seconds with no unread dot left for that entry. Dismissing the notification on the Mac does not remove it from the queue.

## Two-line notifications from scripts

```bash
bin/tbctl notify "Weekly sync" --title "Meeting joined" --app com.microsoft.teams2
```

- `--title` adds the heading line. The text then shows smaller below the heading.
- `--app` shows the icon of that app. The icon has the same size as the App Controls switcher icon (30 pt).
- `teams/teams-watch` sends this notification when you join a Teams call. The second line is the meeting title: the title of the Teams call window, without " | Microsoft Teams". `teams/teams-mute meeting` prints that title.
