# Layouts

The repository has two layouts in `layouts/`:

| Layout | File | Purpose |
|---|---|---|
| Template | `layouts/template.json` | Reference for spacing and look: ✕, gap, three shape placeholders, notification area, two temporary buttons. Change the template only for a deliberate experiment. |
| Actual | `layouts/actual.json` | The everyday bar: ✕, gap, Teams mic, notification area, App Controls ([app-controls.md](app-controls.md)). |

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

- `stickyApps`: notifications from these apps stay `stickySeconds` (default 600 = 10 minutes). Other notifications stay `defaultSeconds`.
- `lobApps`: notifications from these apps show the lob icon. lob sessions send their notifications through kitty.
- `ignoreApps`: MTMR does not show notifications from these apps.
- If a notification has a title and a body, the bar shows two lines: the title as a heading, and the body smaller below. If it has only one of them, the bar shows one line.
- Source: the Notification Center database (`$(getconf DARWIN_USER_DIR)com.apple.notificationcenter/db2/db`). MTMR reads the database once a second, read-only. On macOS 14.7.6, the read needs no Full Disk Access.

## Notification queue

- A new notification shows at once.
- Each notification counts down on its own. A 10-minute notification never holds back a newer one.
- When the shown notification expires, the newest remaining one shows.
- Swipe left or right to move through all live notifications. A touch on the area pauses every countdown.
- If more than one notification is live, a small pulsing dot shows at the top right of the area.
- Notifications leave the bar only when their countdown ends. Dismissing the notification on the Mac does not remove it from the bar.

## Two-line notifications from scripts

```bash
bin/tbctl notify "Weekly sync" --title "Meeting joined" --app com.microsoft.teams2
```

- `--title` adds the heading line. The text then shows smaller below the heading.
- `--app` shows the icon of that app. The icon has the same size as the App Controls switcher icon (30 pt).
- `teams/teams-watch` sends this notification when you join a Teams call. The second line is the meeting title: the title of the Teams call window, without " | Microsoft Teams". `teams/teams-mute meeting` prints that title.
