# Findings

Facts discovered while building this project. Each entry says how it was established.
**Verified** = observed on the real machine. **Source** = read in code or docs. **Unverified** = believed, not tested.

Machine: MacBook Pro, Apple M1 (arm64), macOS 14.7.6, Touch Bar. Work laptop: be careful, back up before changing anything.

---

## 1. MTMR (My TouchBar My Rules)

Repo: https://github.com/Toxblh/MTMR (MIT licence). Presets: https://github.com/Toxblh/MTMR-presets.

### Maintenance status
- Last tagged release: **v0.27.0, 2020-11-20** (Source: `gh release list`). Distributed as `MTMR.0.27.dmg`.
- The repo still receives commits: `2026-05-15 Add arm64 (Apple Silicon) support with universal binary (#476)` (Source: `git log`). That commit is **not in any release**; it exists only in source.
- About 5,600 lines of Swift in `MTMR/MTMR/` (Source: `wc -l`).

### Rosetta 2: the concern is real for the release, not for a source build
- The released app and the Homebrew cask (`brew install --cask mtmr`, version 0.27) are **Intel-only** and need Rosetta 2. Homebrew's own caveat says so. (Source: `brew info --cask mtmr`.)
- Rosetta 2 is **not installed** on this machine (Verified: no `com.apple.pkg.RosettaUpdateAuto` receipt, `oahd` not running).
- Building from the current source produces a universal (arm64 + x86_64) binary and needs no Rosetta (Source: commit #476 and `build.sh` using `ARCHS="arm64 x86_64"`). Not yet built here.

### Building from source: full Xcode is NOT needed
- Upstream's own build (`build.sh`, `xcodebuild`) needs full Xcode, which is not installed here (only Command Line Tools).
- We build natively with the Command Line Tools instead. See section 4 and `runbook-build-mtmr.md`.

### How MTMR is configured (Source: MTMR/README.md, AppDelegate.swift, TouchBarController.swift)
- Config is one JSON file: `~/Library/Application Support/MTMR/items.json`.
- **MTMR watches that file and hot-reloads on every write** (`DispatchSource.makeFileSystemObjectSource` with `.write`, `AppDelegate.reloadOnDefaultConfigChanged`). Writing the file is therefore the control interface. A reload rebuilds the whole preset (`TouchBarController.reloadPreset`). Whether the rebuild flickers is unverified.
- The status-bar menu has "Open preset" (load any JSON file), "Hide Control Strip" (see key finding below), per-app blacklist, haptics, start at login.
- Built-in items: system keys (esc, brightness, volume, mute, media), native widgets (time, battery, cpu, weather, music, dock, dnd, dark mode, pomodoro, network, calendar), and custom ones.
- Custom items: `staticButton`, `appleScriptTitledButton`, `shellScriptTitledButton`, plus `group` and `swipe` gestures.
- **Custom icons are supported.** `image` takes `filePath` or `base64` (resized to 24x24). An AppleScript button can swap its icon at runtime by returning `{"TITLE", "IMAGE_LABEL"}` where the label is a key in `alternativeImages`.
- **Script buttons run on a timer** (`refreshInterval`, seconds). A shell button can colour its background via 16-colour ANSI escape codes in its output.
- Taps run `actions` (`singleTap`, long press): AppleScript, shell, key press, open app.

### KEY FINDING: Apple's real control strip stays on the right; MTMR fills the space between it and esc (Verified 2026-10-02)

This is the layout we are building on. The user confirmed on the real bar: the right-hand side is exactly how Apple does it (the real, system control strip with its native brightness/volume behaviour), and our items live **between MTMR's esc button and Apple's control strip**. Feel was reported as "slightly janky"; cause not investigated (candidates: the whole bar rebuilds on every app switch and config reload, 1-second script polling).

How it works:
- MTMR presents its bar as a "system modal" Touch Bar. Its setting `com.toxblh.mtmr.settings.showControlStrip` (stored in the app's defaults domain, default **false**) chooses how (Source: `AppSettings.swift`, `TouchBarController.presentTouchBar`):
  - `false`: `presentSystemModal(touchBar, placement: 1, ...)`: MTMR takes the **whole** bar and Apple's control strip is hidden. Volume and brightness then have to be MTMR buttons.
  - `true`: `presentSystemModal(touchBar, systemTrayItemIdentifier:)`: **Apple's control strip stays on the right** and MTMR's items fill the rest.
- We set it to `true` for our build:
  ```bash
  defaults write com.maxday.touchbar-interface.mtmr-dev com.toxblh.mtmr.settings.showControlStrip -bool true   # Apple strip on the right
  defaults delete com.maxday.touchbar-interface.mtmr-dev com.toxblh.mtmr.settings.showControlStrip            # back to MTMR owning the whole bar
  ```
  Then quit and reopen MTMR. The menu-bar item **Hide Control Strip** is the same switch: unchecked = Apple's strip shown.
- Consequence for layouts: do not add volume, brightness, mute or Siri items. Apple's strip provides them. Our space is `[esc] [centre: scrolls, per-app] [fixed right-of-ours items]` and then Apple's strip. See `ui-wireframes.md`.
- Experiment files: `experiments/lab-2-layout.json`.
- Not done yet: making `true` the compiled-in default (change `defaultValue` in `AppSettings.swift` via a patch), so a fresh machine or `defaults` reset needs no manual command.

### Layout model and per-item options (Source: TouchBarController.swift, ItemsParsing.swift, ShellScriptTouchBarItem.swift; corrected 2026-10-02)
- The bar is one horizontal row: **left items, one scrolling centre area, right items.** Left and right are fixed; only the centre scrolls (an `NSScrollView`). An item's `align` (`left`/`center`/`right`) picks its zone.
- **Per-app items exist:** the item option `matchAppId` is a regular expression matched (anywhere in the string) against the frontmost app's bundle ID. Non-matching items are not created. It is re-evaluated on every app launch, quit or activation, and the bar is rebuilt only if the set of items changed.
- Item options available on every item: `width`, `align`, `bordered`, `background` (hex colour), `title`, `image`, `matchAppId`.
- `group` opens a sub-bar (popover Touch Bar) that replaces the bar; a `close` item returns.
- **Script buttons** (`shellScriptTitledButton`, `appleScriptTitledButton`) re-run every `refreshInterval` seconds. Output is plain text or JSON `{"title": ..., "image": ...}`. Plain text may carry ANSI colour codes: the **background colour of the first character becomes the button's background** (16 colours). **Empty output hides the button** (its width is forced to 0).
- A config reload rebuilds the whole bar (`createAndUpdatePreset`).

### What MTMR does not have
- No URL scheme, no AppleScript dictionary, no socket or XPC: **no push interface.** Outside programs can only (a) rewrite `items.json`, or (b) be polled by a script button on its timer.
- No way to change one item without either a timer-driven script button or a full config reload.
- **The small "X" at the far left cannot be removed (Verified 2026-10-02, user).** MTMR is an app overlaid on the Touch Bar, and macOS draws that X. MTMR already calls `DFRSystemModalShowsCloseBoxWhenFrontMost(false)` and it still shows.
- **esc is an ordinary item; an empty layout (`[]`) removes it (Verified 2026-10-02, user).** The bar stays under MTMR's control; the user confirmed it with a visible test button.
- The Do Not Disturb button (`dnd`) does not work on this macOS 14.7.6 (user report 2026-10-02, cause not investigated).

---

## 2. Microsoft Teams mute control (works; independent of MTMR)

Approach and reference: `/Users/maxday/Workspace/projects/theboxstuff/cliui/daemon/docs/teams-debug-port-approach.md`.

- Teams "Third-party app API" is **not available** here (absent from Settings > Privacy; likely disabled by IT). The debug-port route was chosen knowingly. It lets any local process control Teams and may break IT policy.
- Setting `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--remote-debugging-port=9333 --remote-allow-origins=*"` before Teams starts opens a DevTools port on `127.0.0.1:9333` only (Verified with `lsof`).
- A LaunchAgent (`~/Library/LaunchAgents/com.maxday.teams-debug-env.plist`, running `sh -c "launchctl setenv ..."` at login) sets it for every launch. The plain `launchctl setenv` form in the plist ran but did not set the variable; wrapping it in `sh -c` worked. Verified with a throwaway app started through LaunchServices. `launchctl getenv` from a shell reads empty and is not a valid check.
- The in-call mic button is `[aria-label*="mic" i]`. Label **"Unmute mic" = muted, "Mute mic" = unmuted.** Clicking it with `.click()` toggles mute without stealing focus. (Verified in a live call, both directions; the user watched Teams change.)
- Call page markers: a visible `Leave` button (`data-tid="hangup-main-btn"`). Four `page` targets exist on `teams.microsoft.com/v2/`; only one holds the mic button.
- After leaving a call, Teams still reported an active call because the user had only closed the window. A call-ended check should require the Leave button as well as the mic button. Unverified after a real leave.
- Code: `teams/` in this repo (`teams-cdp.py`, `teams-mute`, `teams-debug-launch.sh`, `launchd/`). Runbook: [runbook-teams-debug.md](runbook-teams-debug.md).

---

## 3. Native arm64 build of MTMR with Command Line Tools only (Verified 2026-10-02)

MTMR **builds and runs natively on this M1 with no Xcode and no Rosetta.** Result: a 1.1 MB `Mach-O 64-bit executable arm64` (`lipo -archs` = `arm64`, no x86 or Rosetta references), running from `build/MTMR.app`. Repeatable build, patches and troubleshooting: **[runbook-build-mtmr.md](runbook-build-mtmr.md)** (script: `mtmr/build.sh`).

Why it works (facts behind the runbook):
- The Command Line Tools SDK ships link stubs for the private frameworks MTMR needs: `DFRFoundation` (Touch Bar), `MultitouchSupport` (haptics), `CoreBrightness`, `CoreDisplay`.
- The storyboard (`Main.storyboard`) contains only the main menu: no windows, outlets or view controllers, so `ibtool` is not needed.
- **The asset catalogue IS used, and missing it crashes the app.** The code references 12 catalogue images through `#imageLiteral(resourceName:)`. A first run without them crashed with `EXC_BREAKPOINT` while decoding the default `items.json`. All 12 are plain PNGs, so `actool` is not needed either: they ship as `Contents/Resources/<imageset>.png` behind a small loader. Lesson: `grep NSImage(named:)` alone misses image literals; search for `imageLiteral` too.
- Sparkle (the auto-updater, which contacts `mtmr.app`) is referenced in one file only and was removed.
- Link errors met on the way: missing `-fmodules` (clang), and undefined `CoreDisplay_Display_{Get,Set}UserBrightness` until `-framework CoreDisplay` was added.
- Ad-hoc signing ties the Accessibility permission to the signature, so it must be re-granted after each rebuild.
- The default preset triggers prompts for apps that are not there: its iTunes buttons make AppleScript ask "Where is iTunes?" (iTunes no longer exists), and its weather widget needs an API key and Location permission. Removed from the live `items.json` on 2026-10-02 (backup kept).

Related: issue https://github.com/Toxblh/MTMR/issues/403 (people building on M1). The one reported failure was a missing "Developer ID Application" signing certificate, which only affects release archives, not local builds.

---

## Notification area and local push channel (2026-10-06)

- **Verified (build/CLI, not a running Touch Bar):** `mtmr/build.sh` applies diff-generated patch `0002` after `0001`, builds successfully, and `lipo -archs build/MTMR.app/Contents/MacOS/MTMR` prints only `arm64`. Upstream `git status --porcelain` is empty. Existing upstream deprecated-API warnings remain; no upstream files were edited.
- **Verified (CLI tests):** `python3 mtmr/tests/test-notifications.py` covers notify/clear against a throwaway Python server, dry-run JSON without connecting, missing/refused socket exit 3, usage exit 2, server/malformed-reply exit 1, and success exit 0. It also sends commands to the actual Swift socket code in a standalone harness at a temporary path, including invalid JSON, wrong types, unknown commands, the 4096-byte boundary and oversized input; recovery, mode 0600, stale-socket replacement and shutdown cleanup pass. Neither harness launches MTMR.app, creates a Touch Bar, or accesses the live MTMR socket/config/settings.
- **Source:** `notification` options are `maxChars` (default 40, range 1...1000) and `defaultSeconds` (default 5, positive, at most 86400). One notification item owns the centre; other centre items are not displayed alongside it. It ignores `matchAppId`, forces centre alignment, bypasses frontmost-app blacklisting, and uses whole-width presentation even if the old stored control-strip preference is true. Layouts without a notification retain upstream presentation behavior; no defaults setting is changed.
- **Source:** oldest-first queue, at most 256 entries. New arrivals do not interrupt the shown entry. Expiry removes that entry, selects the next (or preceding final entry), and eventually leaves an idle blank area. One-finger up selects next, down selects previous, clamped at the ends. Expiry pauses from pan begin through end/cancel; each entry retains its remaining display time while another is selected. State and timers belong to a main-thread singleton, not the item view, so app switches and config reloads do not reset them. Removing the notification item leaves state running but no display until it is configured again.
- **Source:** one centred monospaced line, 12 pt horizontal padding on each side, 30 pt area height. Whitespace is normalized; text over `maxChars` becomes `maxChars - 1` characters plus an ellipsis. Font scales down from 15 to 8 pt using available width and the configured character budget; the text field also tail-truncates to fit, including wide Unicode glyphs or narrow bars. A single line avoids crowding the 30 pt height.
- **Source:** launch creates `~/Library/Application Support/MTMR/mtmr.sock`, a local Unix stream socket bound under umask 077 and chmod 0600. Only an owned, refused stale socket is unlinked; an active socket or non-socket path is left alone. Quit removes only the socket inode owned by this server. Per-client input buffers are bounded at 4096 bytes, with 16 clients, 16 pending commands per client and a five-second idle timeout; typed JSON decoding, logged errors, nonblocking I/O and disabled SIGPIPE avoid malformed-input traps. Commands run on the main queue; socket I/O does not.
- **Protocol/usage:** one UTF-8 JSON object per newline (4096 bytes before newline): `{"cmd":"notify","text":"build ok","seconds":5}` or `{"cmd":"clear"}`. Omit seconds to use the item's default; supplied seconds must be positive and no more than 86400. Replies are `{"ok":true}` or `{"ok":false,"error":"..."}`. Unknown fields are reserved for extensions, unknown commands rejected; oversized lines close the connection after an error. Use `bin/tbctl notify "build ok" --seconds 5`, `bin/tbctl clear`, or `bin/tbctl --dry-run notify "build ok"`; `--socket PATH` supports isolated tests. The CLI has a five-second timeout and deliberately does not retry commands (which could duplicate notifications).
- **Source (temporary layout):** `layouts/main.json` is `[x diamond][y circle][z triangle] | notification | [temp 1][temp 2]`, with inline 24x24 PNGs and no actions. Left buttons are 90x30 pt (3:1), using upstream's 30 pt button height; the deliberately temporary right `staticButton`s are 150x30 pt as requested, about 1.67 times wider to read as large while preserving centre space. No esc, volume, brightness or Siri items. `layouts/base.json` and the live config are untouched.
- **Unverified:** actual centre expansion, font legibility, seamless Apple-icon height, one-finger vertical gestures, clipping, live config-reload persistence and app-independent visibility on the real Touch Bar. The view carries `#COMPLETION_DRIVE` / `#SUGGEST_VERIFY` tags for physical verification. Expiry/queue/pause were exercised without UI; actual swipe delivery, truncation/rendering and controller reload behavior were checked only in source.
- **Design conflict:** the earlier control-strip passages in this file, `runbook-build-mtmr.md` and `ui-wireframes.md` describe the superseded 2026-10-02 design. This implementation follows the user's 2026-10-06 whole-width brief; those historical passages are left unchanged, not mixed into the new layout.
- **Rollback:** restore the preceding `mtmr/build.sh`, remove patch `0002`, its two overlay files, `bin/tbctl`, `layouts/main.json` and the new `mtmr/tests/` files, then rebuild with patch `0001` only. This task installed nothing and changed no live config, defaults, permissions or LaunchAgents. No configured lint runner was detected; bash syntax and Python syntax checks were used alongside the explicit test command above.

---

## Deterministic notification layout (patch 0003)

- **Verified (resume build/tests):** reused the existing solver, container, harnesses and maths documentation. The first clean build passed; the initial seven-case run failed only because wrong-type item `minWidth` decoding did not log its rejection (`AssertionError: 1 != 2`). Patch `0003` now logs and rethrows both type and range errors; it was regenerated with `diff -u` against scratch copies with `0001` + `0002` applied, and all three patches apply with `--fuzz=0`. A second clean build and all seven tests pass; arm64-only output and the clean upstream checkout were reconfirmed. Resume inputs and the preceding app bundle were backed up to `/tmp/mtmr-layout-resume.aXsets/`; no app was launched.

- **Verified (clean build, not a running Touch Bar):** `mtmr/build.sh` applies `0001`, `0002`, then diff-generated `0003-layout-solver.patch`, and builds successfully with Swift 6.0.3. Both `lipo -archs` and `file` report only arm64; upstream `git status --porcelain` is empty. The script's existing patch/overlay globs already include the new files, so `mtmr/build.sh` is unchanged by this task.
- **Verified (solver tests):** `python3 mtmr/tests/test-notifications.py` runs seven unittest cases, including an AppKit-free Swift solver target. The current JSON produces `Lw=288`, `Rw=208`, `padding=16`, `N=477`, and equal **304 pt bar-edge margins** at `W=1085`; the gaps to the unequal groups are 16/96 pt. Tests cover proportional allocation, left-before-right exhaustion, explicit/default/fixed minima, caps/padding, below-minimum and floor cases, tiny widths, empty/one-sided groups, centring and trailing-edge pins, including fractional runtime width. The six-left-icon example produces `Lw=406`, `N=241`, and margins 422/422; see [layout-maths.md](layout-maths.md) for calculations, options and rollback.
- **Verified (standalone AppKit views, not hardware):** the runner compiles the actual patched sources into a separate harness that creates neither `NSApplication` nor `NSTouchBar` and never accesses the controller singleton. It checks a full-size mock host, bounds resizing/restoration, centred text and unchanged frames for idle/short/long text, decoded options/exit identity, and upstream `NSStackView` behavior without a notification. Existing queue/CLI/socket tests still pass using temporary paths only; the socket server and notification store were not changed.
- **Verified (syntax):** `bash -n mtmr/build.sh` and Python AST parsing of the test runner pass. No configured project lint command was detected. Existing upstream deprecated APIs, unsafe-cast/capture warnings, and the unused `ItemsParsing.swift` up-next `interval` remain unchanged; the existing long parser/controller functions were kept intact apart from minimal hooks.
- **Source:** the notification container pins leading/trailing edges to its single item's host, reads live bounds, and re-solves on width changes; config reload creates a new container. Width constraints from the upstream items are deactivated only in this path, then absolute 30 pt-high frames own the geometry. Nominal widths are captured from configuration or fitting size, not notification text. Raw `exitTouchbar` identity survives alias decoding; blank borderless buttons with no image/background/actions are fixed spacers.
- **Source / tagged policies:** whole-point allocation uses largest remainders; integral centring may reduce a cap by one point. Infeasible minima hide whole overflow items rather than overlap or shrink fixed items; only `W < 120` reduces the hard floor, with padding relaxed only when necessary. Contradictory `maxWidth < minWidth` is rejected. Fractional widths or an odd bar with a 120 pt cap preserve exact centre/edges using fractional origins. These choices and the 1085 pt fallback retain `#COMPLETION_DRIVE` / `#SUGGEST_VERIFY` tags.
- **Unverified (real Touch Bar):** whether the AppKit item host spans all 1085 pt, edge constraints coexist with Apple's private host constraints, runtime width changes are delivered, clipping/font appearance and Apple's icon-height match. No MTMR.app was launched/restarted, and no live JSON, defaults, Accessibility permissions or LaunchAgents were touched. Original edited files and the previous build were copied to `/tmp/mtmr-layout-backup.KRgM5Q/` before changes; the upstream checkout and external backup/preset directories were left alone.
- **Pattern conflicts retained:** `0002-notification-area.patch` used stack `.fill`/hugging for notifications; `0003` deliberately replaces only that branch with the solver, per the latest brief, while keeping the upstream no-notification stack and `0002` queue/presentation path. The earlier 90/150 pt layout paragraph in this file is a historical snapshot; the authoritative `layouts/main.json` is now exit 30, spacer 1, three icons 75 and two temp buttons 100, unchanged here. The superseded Apple-control-strip design in this file, `runbook-build-mtmr.md` and `ui-wireframes.md` is left in place, not blended into the new layout.

---

## 4. Open questions

1. ~~Can MTMR be built here?~~ Yes, see section 4. Xcode and Rosetta 2 are not needed. (Rosetta 2 stays blocked by user decision.)
2. Does an `items.json` rewrite flicker the Touch Bar or reset state?
3. Can an MTMR item set its own background colour directly, and can it be hidden or shown conditionally?
4. Can anything cover or remove Teams' native grey mute button on the Touch Bar?
5. Is there a lighter way for a program to push state to MTMR than rewriting its JSON (for example a local socket added in our fork)?
