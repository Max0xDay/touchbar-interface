# Live buttons and Teams mic

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

Taps use existing MTMR `actions`; there is no new tap transport. The Teams item is:

```json
{
  "type":"staticButton", "id":"teams-mic", "title":"", "align":"left",
  "width":75, "icon":"mic.fill", "tint":"#8e8e93",
  "actions":[{
    "trigger":"singleTap", "action":"shellScript",
    "executablePath":"/Users/maxday/Workspace/projects/maxlaptopmtmr/touchbar-interface/teams/teams-mute",
    "shellArguments":["toggle"]
  }]
}
```

`executablePath` is the absolute executable itself; MTMR passes `shellArguments`
to `Process`, not to an interpolating shell. `$HOME`, `~` and relative repo paths
are not substituted by MTMR. `layouts/actual.json` uses `${REPO}`; `tbctl layout actual`
replaces `${REPO}` with the repository path. The mic starts hidden (`startHidden`) until
the watcher supplies a state.

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

## Teams watcher (manual, not installed)

`teams/teams-watch` polls `teams-mute status` at one-second intervals and sends
only when the full mapped state changes. It never launches/restarts Teams. The
existing debug-port setup and English-label limits are in
[runbook-teams-debug.md](runbook-teams-debug.md).

| Status | Icon | Tint | Visible |
|---|---|---|---|
| exit 0, `unmuted` | `mic.fill` | green `#34c759` | true |
| exit 0, `muted` | `mic.slash.fill` | red `#ff3b30` | true |
| exit 4, no call | `mic.fill` | yellow `#ffcc00` (not drawn) | false, collapses |
| exit 3 / failure / unreadable | `mic.fill` | yellow `#ffcc00` | true |

Each update includes background null and the full icon/tint/visibility state.
Socket absence/refusal retries quietly. Socket device/inode/creation-metadata
changes trigger a full re-send even if status is unchanged; failures retry on the
next cycle. Status calls time out after five seconds, socket operations after two.
Other failures log to stderr and recover to unreadable/yellow or retry delivery.
SIGINT/SIGTERM stops cleanly after any bounded in-flight operation.

User-run commands (none were run against Teams during implementation):

```bash
teams/teams-watch --once                  # print and apply one state
teams/teams-watch --once --dry-run        # still reads Teams; prints, does not apply
teams/teams-watch --interval 1 > /tmp/teams-watch.log 2>&1 &
watcherPid=$!
# Stop only this watcher, not Teams or MTMR:
kill "$watcherPid"
```

`--status-command /absolute/path/fake-status` selects a fake executable receiving
`status`; combine with `--socket /tmp/fake.sock` for testing. `--once` exits 3 if
no state could be applied (0 on successful application or dry-run).

### LaunchAgent illustration only

**Not installed or loaded.** If automation is later approved, a plist could contain:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.maxday.teams-watch</string>
  <key>ProgramArguments</key><array>
    <string>/ABSOLUTE/PATH/TO/python3</string>
    <string>/Users/maxday/Workspace/projects/maxlaptopmtmr/touchbar-interface/teams/teams-watch</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/teams-watch.log</string>
  <key>StandardErrorPath</key><string>/tmp/teams-watch-errors.log</string>
</dict></plist>
```

Replace the interpreter placeholder with `command -v python3` output first. No
installation commands are provided here; installation is a separate approved step.
Rollback for manual use: stop the watcher; restore the previous layout source and
patch/overlay/CLI files from the task's `/tmp/mtmr-live-buttons.5GbJGM/` backup and
rebuild. Any live-layout change or app restart requires separate user approval.

## Verification limits

Run `mtmr/build.sh`, then `bash mtmr/tests/run-tests.sh`. Tests use temporary socket
paths and fake status executables; standalone AppKit views do not create a Touch
Bar or access the controller singleton. The current full-width three-icon fixture
still yields **N=477 at W=1085**. Physical icon sizing/tint, group representation,
Reduce Motion and coordinated animation appearance remain unverified; visible tags
mark those assumptions. Nothing was installed or tried on the real bar/Teams port.

## Watchers and start state

A live button in the layout accepts two more fields:

- `"startHidden": true`: the button starts hidden and collapsed. The watcher shows the button when the watcher has a state. The Teams mic uses this field, so no grey mic shows outside a call.
- `"watcher": ["/absolute/path", "arg", ...]`: MTMR starts this process when the layout loads. MTMR stops the process when a new layout no longer lists it, and when MTMR quits.
  - If the process exits, MTMR starts it again after 1 s. The delay doubles up to 60 s. After 30 s of normal run, the delay goes back to 1 s.
  - The first item must be an absolute path to an executable file. Otherwise MTMR rejects the layout.
  - Output goes to `~/Library/Logs/touchbar-interface/watchers.log`. MTMR starts a new log file when the old file is larger than 1 MB.

The Teams mic uses `teams/teams-watch` as its watcher, so no LaunchAgent is necessary for the mic. A tap runs `teams/teams-mic-tap`. That script toggles the mic and sets the new icon at once.
