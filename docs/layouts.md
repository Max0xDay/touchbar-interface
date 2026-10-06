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

The actual layout uses "Welcome to the bar zone". The template layout has no welcome text.
