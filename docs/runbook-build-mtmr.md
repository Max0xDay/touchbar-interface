# Runbook: build and run MTMR natively on Apple Silicon

The build produces a native arm64 [My TouchBar My Rules (MTMR)](https://github.com/Toxblh/MTMR) app with Xcode Command Line Tools.
The build uses no network access, elevated privileges, full Xcode, or Rosetta.
The reference platform is macOS 14.7.6 on an M1 MacBook Pro (`MacBookPro17,1`).
The overlays include Universal Serial Bus (USB) and external display effects.

Upstream's v0.27.0 release uses Intel binaries.
This repository instead pins arm64-capable source at commit `94fc98c`.
[Findings](findings.md) records platform evidence and private framework limits.

## Prerequisites

| Requirement | Check |
|---|---|
| Apple Silicon | `uname -m` must print `arm64`. |
| Command Line Tools | `xcode-select -p` identifies the tool directory; `swiftc` and `clang` must exist. |
| Python 3 for tests and `tbctl` | `python3 --version` must succeed. The scripts use only the standard library. |
| Clean upstream checkout | `git -C ../MTMR rev-parse HEAD` must print `94fc98cceff94cf69a2e7c28f726cf35ab93c461`. |
| Private framework stubs | The selected software development kit (SDK) must provide the private frameworks listed below. |

If Command Line Tools are absent, request installation with `xcode-select --install`.
The default directory arrangement is:

```text
<project root>/
  MTMR/                  # pristine upstream checkout
  touchbar-interface/    # this repository
```

Set `MTMR_CHECKOUT` to use another upstream checkout.
Keep all project changes in patches and overlays.
Leave upstream files unchanged.

## Build

Run commands from the repository root:

```bash
mtmr/build.sh
bash mtmr/tests/run-tests.sh
```

A build takes about 70 seconds on the reference machine and produces `build/MTMR.app`.
The full test duration varies; the earlier suite took about 150 seconds.
The layout harness compiles sources from `build/work/src`, so rebuild before the full suite after code changes.

The build rejects non-arm64 execution, Rosetta translation, a wrong upstream commit, or upstream changes.
The build prints a step prefix `==>` and finishes with `Built .../build/MTMR.app (arm64)`.
Upstream deprecation and unused-variable warnings can appear.
The build recreates the app bundle and work directory, without a live layout change or app restart.

`run-tests.sh` runs each `test-*.py` file in name order with `python3 -I`.
The shell stops at the first failed file.
Run separate files to check later tests after an earlier failure:

```bash
python3 -I mtmr/tests/test-live-buttons.py
python3 -I mtmr/tests/test-notifications.py
python3 -I mtmr/tests/test-praatvol.py
python3 -I mtmr/tests/test-teams.py
python3 -I mtmr/tests/test-usb.py
python3 -I mtmr/tests/test-volume.py
```

| Test file | Coverage |
|---|---|
| `test-live-buttons.py` | The fixtures check Teams event routing, state mapping, socket delivery, and idle blocking. |
| `test-notifications.py` | The tests check the client, notification store/server, pure solver, standalone area, and prepared layout views. |
| `test-praatvol.py` | A fake socket checks snapshots, progress, review, Saved timing, framing, and reconnects. |
| `test-teams.py` | The tests check titles, snapshots, geometry, clock, and automatic selection. |
| `test-usb.py` | The tests check device/display filters, debounce, and the client USB preview message without hardware access. |
| `test-volume.py` | The tests check the actual layout, native slider containers, press timing, and coalesced writes without device writes. |

The repository also contains `ChargingTrickleTests.swift`, but no Python test currently invokes that harness.
Run the standalone charging harness explicitly:

```bash
swiftc -target arm64-apple-macosx11.0 -swift-version 5 \
  mtmr/overlay/ChargingMonitor.swift mtmr/overlay/ParticleFlowView.swift \
  mtmr/tests/ChargingTrickleTests.swift -framework Cocoa -framework IOKit \
  -o /tmp/mtmr-charging-tests
/tmp/mtmr-charging-tests
```

The harness checks charging conditions, burst timing, trickle intervals, and the four-particle limit without a power-state change.

The full suite currently fails at the stale `testSwiftStoreAndServer` assertion in `mtmr/tests/main.swift:38`:

```text
Precondition failed: After the newer entry expires, the long one shows again
```

The assertion expects a hidden long-lived entry to appear after a newer entry expires.
`NotificationStore.expire()` deliberately leaves the area empty until arrival, swipe, or recall.
The other notification checks and the separate Python test files pass on the reference machine.

Tests use temporary sockets and do not launch the app, install layouts, or toggle live Teams controls.
Some tests instantiate AppKit objects, but the harnesses do not present a hardware Touch Bar.

## Run, stop, rebuild

```bash
open build/MTMR.app
osascript -e 'tell application "MTMR" to quit'
pgrep -lx MTMR
```

`open` launches the app and shows its menu icon.
Quit returns the Touch Bar to macOS.
`pgrep` reports whether MTMR runs.

Grant Accessibility access on first launch through System Settings > Privacy & Security > Accessibility.
Without access, synthetic key events and Visual Studio Code (VS Code) window discovery fail.

After every rebuild, quit MTMR before the permission reset.
The ad-hoc signature changes, so the old grant can remain visible but fail to match the app.
Reset only this bundle's permission:

```bash
osascript -e 'tell application "MTMR" to quit'
tccutil reset Accessibility com.maxday.touchbar-interface.mtmr-dev
open build/MTMR.app
```

1. Enable MTMR in System Settings > Privacy & Security > Accessibility.
2. If MTMR is absent, add `build/MTMR.app` with the plus button.
3. Quit MTMR.
4. Open `build/MTMR.app` again.

Check for stale permission errors after restart:

```bash
/usr/bin/log show --last 1m --style compact --predicate 'subsystem == "com.apple.TCC" AND eventMessage CONTAINS[c] "mtmr-dev"' | grep "Failed to match"
```

Transparency, Consent, and Control (TCC) logs use `Failed to match existing code requirement` for a stale grant.
A stable local signing identity can avoid repeated signature changes; this build uses ad-hoc signing instead.

## Configuration

MTMR reads `~/Library/Application Support/MTMR/items.json`.
First launch copies the bundled upstream `defaultPreset.json` into that path.
A write triggers a reload without restart.

- Preview the actual layout with `bin/tbctl layout actual --dry-run`.
- Install the actual layout with `bin/tbctl layout actual`.
- Use `bin/tbctl layout template` for the reference layout.
- Write the live file in place; atomic replacement breaks the file-descriptor watcher until restart.
- Leave preference `com.toxblh.mtmr.settings.showControlStrip` unset to give the custom bar the full width.

The layout command backs up the live file and retains the newest 20 backups.
[Layouts](layouts.md) describes backup restoration, notifications, universal control, and particles.
The actual layout starts one Teams watcher; Teams controls require the debug port from [the Teams runbook](runbook-teams-debug.md).
Fan control requires a separate ThermalForge daemon; the build neither installs nor starts that daemon.

## What the build changes versus upstream

The script copies upstream into `build/work/src`, applies patches in filename order, and copies all Swift overlays into that directory.
The script leaves the upstream checkout unchanged.

| Patch | Effect |
|---|---|
| `0001-native-build-without-xcode` | The patch adds a code entry point, plain image loading, and removes Sparkle. |
| `0002-notification-area` | The patch adds the notification item and socket lifecycle. |
| `0003-layout-solver` | The patch adds solver geometry and layout options. |
| `0004-live-buttons` | The patch adds validated identifiers, live state, and safe preset rejection. |
| `0005-app-controls-watchers-welcome` | The patch adds App Controls, watcher supervision, mirror setup, and welcome hooks. The patch limits redundant bar presentations. |
| `0006-volume-button` | The patch maps upstream's `volume` item to `VolumeTouchBarItem`, which now opens universal control. |

Overlays implement the queue, socket, solver, live buttons, watcher supervisor, mirror, icons, and App Controls panels.
Other overlays implement Teams state, praatvol, universal control, brightness, volume, charging particles, and USB/display monitoring.

To update patch 0005, prepare upstream with patches 0001–0004 in a scratch repository.
Record that baseline before patch 0005 and the intended edits.
Generate the final patch with `git diff` without `diff --git` and `index` headers.
Keep patch 0006 separate.
Verify the complete sequence with a build.

## How the compile works (and why each flag is there)

1. Bridge files in `CBridge/` compile with `clang -arch arm64 -fmodules -fobjc-arc` and a macOS 11 minimum.
   `-fmodules` permits Objective-C `@import` statements.
2. Swift uses `-target arm64-apple-macosx11.0 -swift-version 5 -O` and the Objective-C bridge header.
   The link step includes the bridge objects.
3. The private framework path comes from `$(xcrun --show-sdk-path)/System/Library/PrivateFrameworks`.
   The build links `DFRFoundation`, `MultitouchSupport`, `CoreBrightness`, and `CoreDisplay`.
4. The bundle contains the executable, overlay `Info.plist`, default preset, and image files.
5. `codesign --force --sign -` applies an ad-hoc signature.
6. `lipo -archs` checks for arm64 only, and `plutil -lint` validates the property list.

CoreDisplay remains a link dependency for upstream brightness code.
Universal control instead loads DisplayServices at runtime because CoreDisplay brightness calls fail on the reference machine.

## Troubleshooting

| Symptom | Cause and action |
|---|---|
| The build reports a wrong upstream commit. | Check out `94fc98c` in the upstream clone, or regenerate the patches for the intended commit. |
| The app exits with `EXC_BREAKPOINT`. | Check `~/Library/Logs/DiagnosticReports/MTMR-*.ips` and bundled images. `BundledImage.swift` stops execution for a missing resource. |
| macOS asks for an absent media app. | An upstream preset invokes that app through AppleScript. Install a repository layout. |
| Keys fail or VS Code shows “No windows”. | Reset and grant Accessibility access through the procedure above. |
| The Touch Bar stays unchanged. | Check `pgrep -lx MTMR`, then inspect `/usr/bin/log show --last 5m --predicate 'process == "MTMR"'`. |
| The log reports notification width below minimum. | The actual 340 pt App Controls zone leaves 292 pt at width 1004. See the layout geometry guide. |
| AppKit reports conflicting widths 32 and 38. | The upstream controls can emit a cosmetic constraint warning. Check visible behaviour separately. |
| The full test runner stops early. | Run later Python files separately and inspect the known stale notification assertion above. |

## Updating to a newer upstream

1. Fetch the upstream revision with `git -C ../MTMR fetch`.
2. Check out the intended revision with `git -C ../MTMR checkout <new-commit>`.
3. Reapply the patch changes in a scratch copy.
4. Regenerate patches with labelled paths relative to the upstream source directory.
5. Update `EXPECTED_UPSTREAM_COMMIT` in `mtmr/build.sh`.
6. Rebuild the app.
7. Run the tests.
8. Verify the Touch Bar.
9. Update the platform evidence in the docs.

## Never

- Use native arm64 tools; the build rejects Rosetta and Intel-only execution.
- Keep the upstream checkout pristine; store changes in this repository's patches and overlays.
