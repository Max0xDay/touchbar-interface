# Runbook: build and run MTMR natively on Apple Silicon

Builds [MTMR](https://github.com/Toxblh/MTMR) (My TouchBar My Rules) as a **native arm64** app on an M1 MacBook Pro, using only the Xcode Command Line Tools.

- No Xcode, no Rosetta 2, no network access, no `sudo`.
- Last verified: 2026-10-07, macOS 14.7.6, Apple M1 (`MacBookPro17,1`), Swift 6.0.3, upstream commit `94fc98c`.

Why this exists: upstream's last release (v0.27.0, 2020) is Intel-only and needs Rosetta 2, and building it normally needs full Xcode. Upstream's source gained arm64 support in May 2026 (commit `94fc98c`) but has no release. Background and evidence: [findings.md](findings.md), sections 1 and 3.

## Prerequisites

| Need | Check |
|---|---|
| Apple Silicon Mac | `uname -m` prints `arm64` |
| Command Line Tools | `xcode-select -p` prints `/Library/Developer/CommandLineTools` (install with `xcode-select --install`) |
| A clean clone of upstream MTMR at the pinned commit, next to this repo | `git -C ../MTMR rev-parse HEAD` prints `94fc98cceff94cf69a2e7c28f726cf35ab93c461` |

Expected layout (the default; override with `MTMR_CHECKOUT`):

```
<project root>/
  MTMR/                  # clone of https://github.com/Toxblh/MTMR (upstream, never edited by us)
  touchbar-interface/    # this repo
```

## Build

```bash
cd touchbar-interface
mtmr/build.sh          # about 70 seconds; output: build/MTMR.app
bash mtmr/tests/run-tests.sh   # all tests, about 150 seconds; build first (one harness compiles from build/work/src)
```

The script refuses to run if it is not on arm64, is under Rosetta, the checkout is not at the pinned commit, or the checkout has local changes. It prints one `==>` line per step and ends with `Built .../build/MTMR.app (arm64)`. Compiler warnings from upstream code (deprecated APIs, unused variables) are normal.

`build/` is git-ignored and safe to delete; the script recreates it.

## Run, stop, rebuild

```bash
open build/MTMR.app          # start (menu-bar icon appears; Touch Bar switches to MTMR)
osascript -e 'tell application "MTMR" to quit'   # stop (macOS gets the Touch Bar back immediately)
pgrep -lx MTMR               # is it running?
```

To rebuild while it runs: build first, then quit and `open` again.

**First run:** macOS asks for **Accessibility** access (System Settings > Privacy & Security > Accessibility). Grant it. Without it, key presses from the bar and the VS Code panel do not work.

**After every rebuild you must reset and re-grant Accessibility.** The app is signed ad hoc (`codesign -s -`), so its signature changes with each build, and macOS ties the permission to the signature of the build that was approved. The old record keeps showing as enabled in Settings, but silently stops matching, so the Touch Bar buttons do nothing. Adding the new app with **+** does not fix it: the bundle ID is the same, so macOS just re-enables the stale record. Fix:

```bash
osascript -e 'tell application "MTMR" to quit'
tccutil reset Accessibility com.maxday.touchbar-interface.mtmr-dev   # deletes only MTMR's own record
open build/MTMR.app                                                   # macOS prompts again
```

Then in System Settings > Privacy & Security > Accessibility switch MTMR on (use **+** and pick `build/MTMR.app` if it is not listed), and quit and reopen MTMR once more.

How to confirm it is fixed: this must print nothing after a restart (use the full path; `log` is a zsh builtin).

```bash
/usr/bin/log show --last 1m --style compact --predicate 'subsystem == "com.apple.TCC" AND eventMessage CONTAINS[c] "mtmr-dev"' | grep "Failed to match"
```

`Failed to match existing code requirement for subject com.maxday.touchbar-interface.mtmr-dev and service kTCCServiceAccessibility` means the permission is stale. A stable local signing identity would avoid all of this; not set up yet.

## Configuration

MTMR reads `~/Library/Application Support/MTMR/items.json` and **reloads it automatically whenever the file is saved** (no restart). On first run it copies `defaultPreset.json` there.

- Install a layout with `bin/tbctl layout actual` (or `template`). The command backs up the live file and writes it in place. See [layouts.md](layouts.md).
- Edit **in place** (save the same file). Replacing the file with a new one (some editors and atomic writes do this) breaks MTMR's file watcher until you restart it.
- Our bar owns the whole width: leave `com.toxblh.mtmr.settings.showControlStrip` unset. Apple's control strip is then not shown.

## What the build changes versus upstream

All changes live in this repo, never in the upstream clone. The script copies the upstream sources to `build/work/`, patches the copy, compiles it.

| Patch | What it changes |
|---|---|
| `0001-native-build-without-xcode` | Starts the app from code (no storyboard), loads the 12 images from plain PNGs, removes the Sparkle updater. `ibtool` and `actool` exist only in Xcode. |
| `0002-notification-area` | The `notification` item type, its queue and the socket server. |
| `0003-layout-solver` | Places left items, the notification area and right items with the layout solver. |
| `0004-live-buttons` | Buttons with an `id` that the socket can change. |
| `0005-app-controls-watchers-welcome` | The `appControls` item type, watcher processes, the notification mirror; presents the bar again only when its items change. |

Our own files are in `mtmr/overlay/`: the notification area, store, solver and socket server, live buttons, `TouchBarIcon`, `WatcherSupervisor`, `NotificationMirror` and the App Controls panels.

To change patch 0005: apply upstream + 0001–0004 in a scratch git repository, commit, apply 0005 and edit, then write `git diff` without the `diff --git` and `index` lines back to the patch file.

## How the compile works (and why each flag is there)

1. **Bridge files** (`CBridge/*.m`, `*.c`) compile with `clang -arch arm64 -fmodules -fobjc-arc`. `-fmodules` is required: Xcode enables Objective-C modules by default, plain `clang` does not (error: "use of '@import' when modules are disabled").
2. **Swift** compiles with `swiftc -target arm64-apple-macosx11.0 -swift-version 5 -O`, the Objective-C bridging header `CBridge/TouchBarPrivateApi-Bridging.h`, and links the bridge objects.
3. **Private frameworks.** MTMR drives the Touch Bar through Apple's private `DFRFoundation`, plus `MultitouchSupport` (haptics), `CoreBrightness` (night shift) and `CoreDisplay` (brightness). The Command Line Tools SDK ships link stubs for them under `$(xcrun --show-sdk-path)/System/Library/PrivateFrameworks`, so `-F` that path and `-framework` each. Forgetting `CoreDisplay` gives `Undefined symbols: _CoreDisplay_Display_GetUserBrightness`.
4. **Bundle**: `Contents/MacOS/MTMR`, `Contents/Info.plist`, `Contents/Resources/` (`defaultPreset.json` + PNGs), then `codesign --force --sign -`.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `build.sh: upstream is at <hash>, patches were made for 94fc98c...` | The upstream clone moved. `git -C ../MTMR checkout 94fc98c`, or regenerate the patches (below). |
| App starts then exits at once; crash report in `~/Library/Logs/DiagnosticReports/MTMR-*.ips` with `EXC_BREAKPOINT` | A missing bundled image (force-unwrapped lookup). Check `Contents/Resources/*.png` exists and that `BundledImage.swift` is in the build. |
| macOS asks "Where is iTunes?" or similar | A preset button runs AppleScript for an app that is not installed. Remove that item from `items.json`. |
| Bar keys do nothing, or VS Code shows "No windows" | Accessibility permission missing or stale after a rebuild; see Run, above. |
| Touch Bar did not change | `pgrep -lx MTMR`; read the log with `/usr/bin/log show --last 5m --style compact --predicate 'process == "MTMR"'`. Use the full path: `log` is a zsh builtin. |
| Layout warning "Unable to simultaneously satisfy constraints ... width == 32 ... width == 38" | Harmless upstream cosmetic warning. |

## Updating to a newer upstream

1. `git -C ../MTMR fetch && git -C ../MTMR checkout <new commit>`.
2. Copy the files listed above into a scratch directory, re-apply the changes by hand, and regenerate the patch with `diff -u --label a/<file> --label b/<file> <upstream file> <changed file>`.
3. Update `EXPECTED_UPSTREAM_COMMIT` in `mtmr/build.sh`, rebuild, run, check the Touch Bar, update the "last verified" line above.

## Never

- Never install or run anything through Rosetta 2 (`softwareupdate --install-rosetta`, `arch -x86_64`, Intel-only binaries). This is a hard project rule.
- Never write MTMR changes into the upstream clone; keep them as patches and overlays here.
