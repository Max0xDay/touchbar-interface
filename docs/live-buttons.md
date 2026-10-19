# Live buttons and watchers

Patch `0004-live-buttons.patch` and the live-button overlays extend the existing
0600 Unix socket. Commands run on the main thread and do not call `reloadPreset`
or write configuration. Button appearance changes reuse the same view; visibility
changes solve frames in the existing notification container.

## Socket protocol

Default path: `~/Library/Application Support/MTMR/mtmr.sock`. One UTF-8 JSON object
per newline, at most **4096 bytes before the newline**. Replies are newline-delimited
`{"ok":true}` or `{"ok":false,"error":"..."}`; `buttons` adds the listing below.
Unknown extra fields remain reserved for extensions. Client timeout: five seconds.

```json
{"cmd":"notify","text":"build ok","seconds":8}
{"cmd":"clear"}
{"cmd":"button","id":"teams-mic","icon":"mic.fill","tint":"#34c759","background":null,"visible":true}
{"cmd":"button","id":"teams-mic","iconPath":"/absolute/path/mic.png"}
{"cmd":"buttons"}
```

- `notify`: required string `text`; optional positive finite `seconds`, at most
  86400. Omission uses `defaultSeconds` (8 by default). Queue/swipe/expiry behavior
  is unchanged. `clear` clears only notifications, **not button state**.
- `button`: required known string `id`. Any subset of `icon`, `iconPath`, `tint`,
  `background`, `visible` can follow. Omitted fields retain their values; JSON
  `null` restores that field's layout default. Resetting either icon source restores
  the layout icon source. A non-null icon source replaces the other source.
- `icon`: SF Symbol name, rendered icon-only, regular 17 pt, template tinted.
  Unknown names return `unknown icon`. `iconPath` is an alternative absolute,
  readable PNG path, rendered as a 17×17 template image. Supplying both non-null
  sources is rejected.
- `tint` / `background`: `#rrggbb` strings or null. Tint defaults to the layout
  `tint` or AppKit's native tint; background defaults to the layout background.
- `visible`: boolean or null (layout default is true). False disables taps and
  fades to alpha 0. **Hidden buttons collapse by default**, with visible-only 8 pt
  gaps, an edge-pinned group and a newly centred notification. Optional layout
  `keepSlotWhenHidden:true` instead reserves the slot. No `collapseWhenHidden`
  option exists. See [layout-maths.md](layout-maths.md).
- Visibility transitions animate frames and alpha together for 0.2 s ease-in-out;
  Reduce Motion or notification `fadeSeconds:0` disables this animation. Model
  frames are set immediately to the final pure solution. Rapid changes sample the
  presentation layers, cancel prior animations and start toward the latest solution.
  Appearance-only changes do not move frames; there is no colour cross-fade.
- `buttons` replies, for example:
  `{"ok":true,"buttons":[{"id":"teams-mic","icon":"mic.fill","iconPath":null,"tint":"#34c759","background":null,"visible":true}]}`.
  It lists currently bound buttons, sorted by id. A configured file/base64 image
  has null symbol/path fields until overridden. Unknown ids return `unknown button`.
  Invalid field types, colours or icons reject the whole command without mutations.

## Item ids, defaults and taps

Optional item `id` must match `[a-z0-9-]{1,32}` and be unique across the entire
layout, including nested groups. Invalid ids or duplicates log `MTMR layout
rejected` and keep the previous preset. Items without ids retain normal MTMR
behavior and cannot be addressed over the socket. Layout `icon` / `iconPath` and
`tint` set initial appearance even without an id.

The main-thread store retains overrides by id across reload/app-switch rebuilding,
including temporarily absent ids. Newly constructed views receive those overrides
against the **new layout defaults**. State is in memory, not persisted across app
exit; a watcher must re-send on restart. Script/widget refresh code still runs as
upstream implements it; use a `staticButton` when the socket is to own its appearance.
Group child buttons bind when their sub-bar is opened. The native collapsed group
view path is tagged for hardware verification.

Taps use existing MTMR `actions`; there is no new tap transport. This is an optional standalone mic-button example, not part of the everyday layout:

```json
{
  "type":"staticButton", "id":"teams-mic", "title":"", "align":"left",
  "width":75, "icon":"mic.fill", "tint":"#8e8e93",
  "actions":[{
    "trigger":"singleTap", "action":"shellScript",
    "executablePath":"/path/to/touchbar-interface/teams/teams-mute",
    "shellArguments":["toggle"]
  }]
}
```

`executablePath` is the absolute executable itself; MTMR passes `shellArguments`
to `Process`, not to an interpolating shell. `$HOME`, `~` and relative repo paths
are not substituted by MTMR. `layouts/actual.json` uses `${REPO}`; `tbctl layout actual`
replaces `${REPO}` with the repository path. Teams mic/camera now live in the `teams` App Controls panel, not socket-addressable left buttons; the button-protocol examples above require corresponding layout items.

### Add another live button in three steps

1. Add a `staticButton` with a unique valid `id`, explicit width, empty title,
   optional `icon`/`tint` defaults and existing `actions` in the layout. Loading
   that layout is a one-time config change (back up the live file first).
2. Send state without touching the layout:
   `bin/tbctl button build-light --icon checkmark --tint '#34c759' --show`.
3. Give the state-producing script a restart re-sync strategy; use `bin/tbctl
   buttons` to inspect currently registered ids/defaults/effective state.

## CLI

```bash
bin/tbctl notify "build ok" --seconds 8
bin/tbctl clear
bin/tbctl button teams-mic --icon mic.slash.fill --tint '#ff3b30' --show
bin/tbctl button teams-mic --icon-path /absolute/path/mic.png --background none
bin/tbctl button teams-mic --hide
bin/tbctl buttons
bin/tbctl --dry-run button teams-mic --tint none --show
```

`--icon` and `--icon-path` are mutually exclusive; `--hide` and `--show` likewise.
`none` resets tint/background. Raw JSON supports null resets for all fields.
`--socket PATH` supports isolated testing; `--dry-run` prints JSON without connecting.
Listing replies may exceed 4 KB, so the CLI permits up to 1 MiB replies; the request
limit remains 4 KB. Exit 0 success, 1 rejected/transport/bad reply, 2 usage,
3 missing/refused socket: **MTMR is not running (no socket)**. No command retries
(which could duplicate notifications).

## Teams watcher

Teams uses a dedicated [App Controls panel](app-controls.md#teams), not left live buttons. One `teams/teams-watch` process is supervised from the `appControls` item. It sends `teams` snapshots over the same socket, using browser CDP target events and a DOM MutationObserver rather than one-second status polling. No LaunchAgent is needed. The debug-port setup and English-label limits remain in [runbook-teams-debug.md](runbook-teams-debug.md).

```bash
teams/teams-watch --dry-run   # read-only Teams observer; print changes, do not contact MTMR
teams/teams-watch --socket /tmp/fake.sock  # alternate MTMR socket
```

The old `--device`, `--interval`, `--status-command` and `--once` polling options are removed. One-shot `teams-cdp.py` / `teams-mute` commands still work. Tap scripts toggle once and no longer send obsolete `button teams-mic` / `button teams-camera` updates. Never run a toggle during development. State mapping and event routing tests use pure fixtures; they do not click Teams.

## Verification limits

Run `mtmr/build.sh`, then `bash mtmr/tests/run-tests.sh`. Tests use temporary socket
paths and event fixtures; standalone AppKit views do not create a Touch
Bar or access the controller singleton. The current full-width three-icon fixture
still yields **N=477 at W=1085**. Physical icon sizing/tint, group representation,
Reduce Motion and coordinated animation appearance remain unverified; visible tags
mark those assumptions. The Teams watcher has a read-only idle-port check documented in [app-controls.md](app-controls.md#teams); no live controls were clicked or installed.

## Watchers and start state

A live button accepts `startHidden`; every top-level layout item, including `appControls`, accepts `watcher`:

- `"startHidden": true`: the button starts hidden and collapsed. A watcher can show the button when it has a state.
- `"watcher": ["/absolute/path", "arg", ...]`: MTMR starts this process when the layout loads. MTMR stops the process when a new layout no longer lists it, and when MTMR quits.
  - If the process exits, MTMR starts it again after 1 s. The delay doubles up to 60 s. After 30 s of normal run, the delay goes back to 1 s.
  - The first item must be an absolute path to an executable file. Otherwise MTMR rejects the layout.
  - Output goes to `~/Library/Logs/touchbar-interface/watchers.log`. MTMR starts a new log file when the old file is larger than 1 MB.

The actual layout attaches `teams/teams-watch` to App Controls and declares `teams` after `system` in `panels`. The panel runs `teams/teams-mic-tap` and `teams/teams-camera-tap` asynchronously, with optimistic icon state until watcher confirmation. There are no Teams live-button IDs in the actual layout.
