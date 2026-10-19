# Live buttons and watchers

Patch `0004-live-buttons.patch` and the overlays extend My TouchBar My Rules (MTMR) with a local Unix socket.
Socket updates run on the main thread without a preset reload or configuration write.
Appearance updates reuse the same view.
Visibility updates recalculate frames in the notification container.

## Socket protocol

The default path is `~/Library/Application Support/MTMR/mtmr.sock`, with permissions 0600.
Each request contains one newline-terminated JavaScript Object Notation (JSON) object in Unicode Transformation Format, 8-bit (UTF-8).
The request limit is 4096 bytes before the newline.
Replies use `{"ok":true}` or `{"ok":false,"error":"..."}`, followed by a newline.
Listing commands add fields to the success reply.

The server permits 16 simultaneous clients and 16 pending commands per client.
The server disconnects a client after 5 seconds without input.
Unknown commands fail; unknown extra fields do not affect supported commands.
Recognised fields still require the types that their command decoders expect.

These button examples require a custom layout item named `build-light`:

```json
{"cmd":"notify","text":"build ok","seconds":8,"title":"Build","app":"com.apple.Terminal"}
{"cmd":"clear"}
{"cmd":"button","id":"build-light","icon":"checkmark","tint":"#34c759","background":null,"visible":true}
{"cmd":"button","id":"build-light","iconPath":"/absolute/path/build.png"}
{"cmd":"buttons"}
```

- `notify` requires string `text`.
  Optional `seconds` must be finite, positive, and at most 86400.
  Omission uses the layout's `defaultSeconds`, normally 8.
  Optional string `title` adds a heading; optional string `app` selects an app icon by bundle identifier.
  Each display lasts at most 8 seconds; [layouts.md](layouts.md#notification-queue) defines lifetime and recall.
- `clear` clears notifications without a button-state change.
- `button` requires a known string `id`.
  Any subset of `icon`, `iconPath`, `tint`, `background`, and `visible` can follow.
  Omitted fields preserve overrides; null restores the layout default.
  Null for either icon field restores the layout's original icon source.
  A non-null icon source replaces the other source.
- `icon` accepts an Apple system symbol name and produces an icon-only button.
  `TouchBarIcon` uses an 18-point (pt) box and permits wide glyphs up to 1.4 times that width.
  Unknown symbols return `unknown icon`.
- `iconPath` accepts an absolute path to a readable Portable Network Graphics (PNG) image.
  The file must have a `.png` suffix, a valid signature, and an image that AppKit can decode.
  The same 18 pt icon rules apply.
  Two non-null icon sources reject the request.
- `tint` and `background` accept `#rrggbb` or null.
  The layout supplies their defaults; an absent tint uses the native appearance.
  The renderer draws explicit tints into images because the Touch Bar ignores `contentTintColor`.
- `visible` accepts a boolean or null.
  False disables actions and fades the view out.
  Hidden buttons collapse unless the layout sets `keepSlotWhenHidden: true`.
  The layout default is visible unless `startHidden: true` applies.

Invalid button fields reject the whole update without a state change.
Unknown identifiers return `unknown button`.
The `buttons` reply lists currently bound buttons in identifier order:

```json
{"ok":true,"buttons":[{"id":"build-light","icon":"checkmark","iconPath":null,"tint":"#34c759","background":null,"visible":true}]}
```

A layout image from a file or Base64 source has null symbol/path fields until a socket override replaces the image.
The actual layout has no socket-addressable live buttons; `volume` identifies a different item type.

Visibility changes animate frames and alpha together over 0.2 seconds with ease-in-out.
Reduce Motion or notification `fadeSeconds: 0` disables that animation.
Model frames change immediately to the final solver geometry.
Rapid updates sample presentation layers before the next animation.
Fully transparent views also become hidden after the fade, so invisible controls cannot intercept touches.
Appearance-only updates leave frames unchanged and use no colour fade.

## Item ids, defaults and taps

The optional `id` must match `[a-z0-9-]{1,32}` and remain unique across the whole layout, including nested groups.
Invalid or duplicate identifiers log `MTMR layout rejected` and preserve the previous preset.
An item without an identifier cannot receive socket updates.
Layout `icon`, `iconPath`, and `tint` still establish appearance without an identifier.
Live state binds to custom buttons and collapsed group buttons, not every item type with an identifier.

The store preserves overrides by identifier across reloads and app switches, including temporarily absent identifiers.
New views combine those overrides with the new layout defaults.
The store keeps state only in memory; the source must send state again after app restart.
Use `staticButton` if the socket owns appearance; other widgets retain their own refresh code.
Group children bind after the sub-bar opens.
The collapsed group representation retains a hardware verification note in the source.

Taps use ordinary MTMR `actions`; the socket adds no tap transport.
This custom button runs an executable once per tap:

```json
{
  "type":"staticButton", "id":"build-light", "title":"", "align":"left",
  "width":75, "icon":"checkmark", "tint":"#8e8e93",
  "actions":[{
    "trigger":"singleTap", "action":"shellScript",
    "executablePath":"/absolute/path/build-status",
    "shellArguments":["open"]
  }]
}
```

`executablePath` must name the executable itself.
MTMR passes `shellArguments` to `Process`, not to a shell.
MTMR does not expand `$HOME`, `~`, or relative paths.
The local `tbctl layout` command expands `${REPO}` before installation.

### Add another live button in three steps

1. Add a `staticButton` with a unique identifier, explicit width, empty title, and optional appearance/actions.
   Install the layout once with `bin/tbctl layout actual` after a dry run.
2. Send state with `bin/tbctl button build-light --icon checkmark --tint '#34c759' --show`.
3. Make the source send state again after restart.
   Inspect effective state with `bin/tbctl buttons`.

## CLI

The command-line interface (CLI) accepts these forms:

```text
bin/tbctl notify TEXT [--seconds SECONDS] [--title TITLE] [--app BUNDLE_ID]
bin/tbctl particles [--usb | --trickle {on,off}] [--count COUNT] [--seconds SECONDS] [--color COLOR] [--style {dots,sparks}]
bin/tbctl clear
bin/tbctl buttons
bin/tbctl app [ID]
bin/tbctl fan [{apple,quiet,cool,max,custom}] [--percent PERCENT]
bin/tbctl layout [NAME]
bin/tbctl button ID [--icon ICON | --icon-path ICON_PATH] [--tint TINT] [--background BACKGROUND] [--hide | --show]
```

Every subcommand also accepts `-h`/`--help`, `--socket PATH`, and `--dry-run`.
The client accepts shared options before or after the subcommand.
`layout` changes a local file, so `--socket` has no effect on `layout`.
`--dry-run` prints JSON without a connection, or the rendered file for a named layout.

```bash
bin/tbctl notify "build ok" --seconds 8
bin/tbctl clear
bin/tbctl button build-light --icon checkmark --tint '#34c759' --show
bin/tbctl button build-light --icon-path /absolute/path/build.png --background none
bin/tbctl button build-light --hide
bin/tbctl buttons
bin/tbctl --dry-run button build-light --tint none --show
```

`--icon` and `--icon-path` are mutually exclusive.
`--hide` and `--show` are mutually exclusive.
`none` resets tint or background; raw JSON supports null resets for every mutable field.
`--socket PATH` permits a temporary test socket and expands `~`.
The client uses a 5-second socket timeout and permits replies up to one mebibyte (MiB).
The client never retries a command.

| Exit code | Meaning |
|---|---|
| 0 | The command succeeds. |
| 1 | A rejection, transport error, or invalid reply prevents success. |
| 2 | The arguments are invalid, or a layout name is unknown. |
| 3 | The socket is absent or refuses connection: `MTMR is not running (no socket)`. |

`app` without an identifier sends socket command `apps`; `apps` is not a CLI subcommand.
The socket also accepts feature command `teams`, without a corresponding CLI subcommand.
[App Controls](app-controls.md#socket-commands) defines `app`, `apps`, `teams`, and `fan`.
[Layouts](layouts.md#charging-particles) defines `particles`, including `--trickle`, `--usb`, and burst options.

## Teams watcher

Teams uses an [App Controls panel](app-controls.md#teams), not left live buttons.
One `teams/teams-watch` process runs under the supervisor from the actual layout's `appControls` item.
The watcher sends `teams` snapshots through the same MTMR socket.
The watcher uses browser Chrome DevTools Protocol (CDP) events and a Document Object Model (DOM) MutationObserver.
The watcher performs no periodic target or DOM queries.
No separate LaunchAgent starts the watcher.

```bash
teams/teams-watch --dry-run
teams/teams-watch --socket /tmp/fake.sock
```

`--dry-run` observes Teams without toggles and prints changed messages instead of contacting MTMR.
`--socket` selects an alternate MTMR socket.
These are the only watcher options apart from help.
`TEAMS_DEBUG_PORT` selects the CDP port, with default 9333.
The [Teams runbook](runbook-teams-debug.md) describes port setup and English labels.

The watcher blocks on the browser socket while idle.
Connection failures retry after 5, 10, and then at most 30 seconds.
Failed state deliveries retry after 5 seconds; notification deliveries never retry.
One-shot `teams-cdp.py` and `teams-mute` commands remain separate from the watcher.
The panel's tap scripts only toggle once; the watcher confirms state.

## Verification limits

Run `mtmr/build.sh` before `bash mtmr/tests/run-tests.sh` because the layout harness compiles from `build/work/src`.
The runner discovers `test-*.py` files and stops at the first failed file.
The [build runbook](runbook-build-mtmr.md#build) lists focused tests and the known stale notification assertion.
Tests use temporary sockets and fixtures rather than live Teams controls.
The three-icon solver fixture uses width 1085 and notification width 477; the fixture does not represent the actual layout.
The real host measures 1004 × 30 pt.

Hardware checks remain necessary for icon appearance, group representation, coordinated animation, and Reduce Motion.
Source verification tags distinguish those checks from fixture coverage.

## Watchers and start state

A live button accepts `startHidden`; every top-level layout item accepts `watcher`.

- `"startHidden": true` starts a bound button hidden and collapsed.
  The source can reveal the button after the source obtains state.
- `"watcher": ["/absolute/path", "argument", "..."]` declares one supervised process.
  The first element must name an absolute executable file, or the layout fails validation.
- MTMR deduplicates identical command arrays.
  MTMR starts each process on layout load and stops unused processes on a later load.
  MTMR also stops all supervised processes on quit.
- An exited process restarts after 1 second.
  Each failure doubles the delay up to 60 seconds.
  A run longer than 30 seconds resets the restart delay to 1 second.
- The supervisor appends output to `~/Library/Logs/touchbar-interface/watchers.log`.
  At log open, the supervisor replaces a log larger than 1,000,000 bytes.
  The supervisor does not rotate the log continuously.

The actual layout places `teams` after `system` and attaches one watcher to App Controls.
The panel invokes `teams-mic-tap` and `teams-camera-tap` through its `teams.directory` option.
Neither script sends live-button updates.
