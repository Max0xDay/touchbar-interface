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
bash tests/run-tests.sh
```

A build takes about 70 seconds on the reference machine and produces `build/MTMR.app`.
The full test duration varies with the available compiler resources.
The layout and core binding harnesses compile prepared sources from `build/work/src`.
Rebuild before tests or coverage after source changes.

The build rejects non-arm64 execution, Rosetta translation, a wrong upstream commit, or upstream changes.
The build prints a step prefix `==>` and finishes with `Built .../build/MTMR.app (arm64)`.
Upstream deprecation and unused-variable warnings can appear.
The build recreates the app bundle and work directory, without a live layout change or app restart.

### Stable signing identity

For local builds, create the optional **MTMR Local Signing** identity once, after reviewing the preview:

```bash
mtmr/make-signing-identity.sh --dry-run
mtmr/make-signing-identity.sh
mtmr/build.sh
```

The setup script creates a self-signed RSA 2048 certificate valid for 10 years, with digital-signature key usage and code-signing extended key usage.
It packages the certificate and private key with a random one-time password and imports them into `~/Library/Keychains/login.keychain-db`, allowing `/usr/bin/codesign` to access the key.
Temporary files are removed on exit; no system trust settings are changed.
It refuses to replace an existing identity with the same name, including an untrusted one.
The dry run only prints steps and commands; it does not inspect or modify the keychain or create temporary files.
macOS may show a keychain prompt, “codesign wants to use key”; choose **Always Allow**.

The build prints whether it uses this identity or ad-hoc signing.
It searches all code-signing identities, not only trusted ones (`security find-identity -p codesigning`, without `-v`).
CI has no local identity and continues to use ad-hoc signing.
Verify the signer after building:

```bash
codesign -dv --verbose=2 build/MTMR.app 2>&1 | grep -i authority
```

Expect `Authority=MTMR Local Signing`.
The first rebuild after switching from ad-hoc signing still needs one Accessibility regrant because the signing identity changed.
After that, rebuilds signed with the same identity should retain the grant: quit and reopen MTMR without `tccutil reset` using the routine below.
This retention still needs confirmation on the reference Mac across two locally signed rebuilds; setup does not launch the app or change Accessibility permissions.
Keep the identity: deleting and recreating a certificate with the same name changes its cryptographic identity.

Rollback removes the certificate and its private key:

```bash
security delete-identity -c "MTMR Local Signing"
```

The next build falls back to ad-hoc signing and needs the Accessibility reset/regrant routine again.
An already-built app keeps its existing signature until rebuilt.

### Branding

After copying upstream images, the build installs `mtmr/branding/StatusImage.png` for both the menu bar and Touch Bar control strip, plus `AppIcon.icns` for the app icon.
Both assets must exist; regeneration is optional and uses only AppKit and `iconutil`:

```bash
logoDirectory="$(mktemp -d /tmp/touchbar-branding.XXXXXX)"
swift mtmr/branding/make-logo.swift "$logoDirectory"
cp "$logoDirectory/StatusImage.png" "$logoDirectory/AppIcon.icns" mtmr/branding/
```

The temporary directory also contains the 1024 px master and all iconset sizes for review.
Back up the committed assets before replacing them; restore them from that backup to roll back.
Patch `0007-status-item-wide-logo` uses a variable-width menu-bar slot and sizes the template image to 18 pt high with proportional width (49.5 pt for the 88 × 32 logo).
The Touch Bar control-strip button has no square size constraint and keeps its default proportional downscaling within the 30 pt bar.
Hardware appearance still needs review after the next user-controlled rebuild and restart.

## Tests and coverage

Core tests cover the basics of `NotificationLayoutSolver.swift`, `NotificationStore.swift`, `NotificationSocketServer.swift`, `LiveButtonStore.swift`, `LiveButtonBinding.swift`, and `WatcherSupervisor.swift` in `mtmr/overlay/`, plus `bin/tbctl`.
A change to core code must come with a core test for the changed behaviour.
Feature-specific and app-specific changes need no new tests; all existing tests must still pass.
The [README test policy](../README.md#tests-and-contributions) lists the full source paths.

Build first, then run the suite and informational coverage report:

```bash
mtmr/build.sh
bash tests/run-tests.sh
bash tests/coverage.sh
```

The test runner runs `tests/core/test-*.py` before `tests/features/test-*.py`, in filename order within each directory.
Each file runs with `python3 -I`.
The runner prints each path and exits nonzero on the first failure.
Run focused files to investigate failures:

```bash
python3 -I tests/core/test-notifications.py
python3 -I tests/core/test-live-state.py
python3 -I tests/core/test-tbctl.py
python3 -I tests/features/test-live-buttons.py
python3 -I tests/features/test-views.py
python3 -I tests/features/test-praatvol.py
python3 -I tests/features/test-teams.py
python3 -I tests/features/test-usb.py
python3 -I tests/features/test-volume.py
```

| Test file | Behaviours |
|---|---|
| `core/test-notifications.py` | Solver geometry, queue lifetimes, display deadlines, recall, socket protocol, malformed requests, queue limits, and multiple clients. |
| `core/test-live-state.py` | Actual button/group bindings and fake watcher starts, stops, retries, and restart backoff. |
| `core/test-tbctl.py` | Remaining CLI commands, dry runs, temporary layout installation, backup retention, reply framing, and representative error exits. |
| `features/test-live-buttons.py` | Teams event routing, state mapping, socket delivery, and idle blocking. |
| `features/test-views.py` | Actual layout validation, notification views, prepared layout views, live visibility, and notification mirroring. |
| `features/test-praatvol.py` | Snapshots, progress, review, Saved timing, framing, and reconnects through a fake socket. |
| `features/test-teams.py` | Titles, snapshots, geometry, clock, and automatic selection. |
| `features/test-usb.py` | Device/display filters, debounce, and accessory preview messages without hardware access. |
| `features/test-volume.py` | Actual layout, native slider containers, press timing, and coalesced writes without device writes. |

The coverage script compiles core Swift harnesses with `-profile-generate -profile-coverage-mapping`.
It merges profiles with `xcrun llvm-profdata` and reports the explicit core files with `xcrun llvm-cov report`.
Coverage is informational; there is no target.
Only core tests contribute to the report; feature code does not count.

The script also measures `bin/tbctl` with `coverage.py` when that development tool is available.
It measures subprocess commands and the extensionless script loaded directly by core tests.
Without `coverage.py`, the script reports Swift coverage only.
You may install `coverage.py` separately in your development environment.
The scripts never install tools; the product remains standard-library-only.

The script prints the temporary artifact directory, per-file tables, and totals.
It exits nonzero only for failed tests or tooling errors.
Exclusions come only from the explicit core file list; tests use no per-line coverage exclusions.

The repository also contains `ChargingTrickleTests.swift`, but no Python test currently invokes that harness.
Run the standalone charging harness explicitly:

```bash
swiftc -target arm64-apple-macosx11.0 -swift-version 5 \
  mtmr/overlay/ChargingMonitor.swift mtmr/overlay/ParticleFlowView.swift \
  tests/features/ChargingTrickleTests.swift -framework Cocoa -framework IOKit \
  -o /tmp/mtmr-charging-tests
/tmp/mtmr-charging-tests
```

The harness checks charging conditions, burst timing, trickle intervals, and the four-particle limit without a power-state change.

The queue checks let the real eight-second display deadline expire while preserving the notification lifetime.
They recall hidden entries without extending their lifetime.

Tests use temporary sockets, directories, and a temporary home for watcher logs.
Layout installation tests redirect every destination into temporary directories.
Tests never install a live layout, launch the app, or control live Teams calls.
Some tests instantiate AppKit objects, but the harnesses never present a hardware Touch Bar.

## Pull requests and lint

Work on a `task/*` branch and open a pull request into `main`.
The **PR validation** workflow must pass before merge.
The stable required check is `validate`; branch protection is configured separately.
The workflow validates every pull request into `main`, pushes to `main`, and manual runs.
It rejects pull requests from branches outside `task/*`.

The job runs on the Apple Silicon `macos-15` hosted runner.
It clones upstream beside the repository at the pinned commit, builds, runs all tests, and runs SwiftLint and Ruff.
It installs development tools separately; build and test scripts perform no network access.
Coverage tables appear in the workflow summary as information only, with no coverage threshold.
Failed builds, tests, lint errors, or coverage tooling errors fail the check.
SwiftLint warnings do not fail the check.

Install lint tools in your development environment, then run from the repository root:

```bash
brew install swiftlint
python3 -m venv /tmp/touchbar-dev-environment
source /tmp/touchbar-dev-environment/bin/activate
python3 -m pip install ruff coverage
swiftlint lint --config .swiftlint.yml
ruff check bin/tbctl teams tests
```

`.swiftlint.yml` scopes correctness checks to `mtmr/overlay` and `tests` without imposing new style rules.
`ruff.toml` checks Python in `teams` and `tests`, plus `bin/tbctl` and `teams/teams-watch`.
The configs allow existing long lines and test imports that follow harness-path setup.
Development tools are not product dependencies.

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

With the stable signing identity and an existing grant for it, restart after a completed rebuild without resetting Accessibility:

```bash
osascript -e 'tell application "MTMR" to quit'
sleep 2
open build/MTMR.app
```

Do not restart while the build is still running.
For **ad-hoc builds**, reset and regrant after every rebuild.
Also use this reset/regrant routine once after switching from ad hoc to the local signing identity.
The changed signature can leave an old grant visible but unable to match the app.
Quit before resetting only this bundle's permission:

```bash
osascript -e 'tell application "MTMR" to quit'
sleep 2
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
The optional [stable signing identity](#stable-signing-identity) avoids the changing ad-hoc identity; the build falls back to ad hoc when it is absent.

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

The script copies upstream into `build/work/src`, applies patches 0001–0007 in filename order, and copies all Swift overlays into that directory.
The script leaves the upstream checkout unchanged.

| Patch | Effect |
|---|---|
| `0001-native-build-without-xcode` | The patch adds a code entry point, plain image loading, and removes Sparkle. |
| `0002-notification-area` | The patch adds the notification item and socket lifecycle. |
| `0003-layout-solver` | The patch adds solver geometry and layout options. |
| `0004-live-buttons` | The patch adds validated identifiers, live state, and safe preset rejection. |
| `0005-app-controls-watchers-welcome` | The patch adds App Controls, watcher supervision, mirror setup, and welcome hooks. The patch limits redundant bar presentations. |
| `0006-volume-button` | The patch maps upstream's `volume` item to `VolumeTouchBarItem`, which now opens universal control. |
| `0007-status-item-wide-logo` | The patch gives the menu-bar template logo a variable-width slot and proportional sizing at 18 pt high. |

Overlays implement the queue, socket, solver, live buttons, watcher supervisor, mirror, icons, and App Controls panels.
Other overlays implement Teams state, praatvol, universal control, brightness, volume, charging particles, and USB/display monitoring.

To update patch 0005, prepare upstream with patches 0001–0004 in a scratch repository.
Record that baseline before patch 0005 and the intended edits.
Generate the final patch with `git diff` without `diff --git` and `index` headers.
Keep patches 0006 and 0007 separate.
Verify the complete sequence with a build.

## How the compile works (and why each flag is there)

1. Bridge files in `CBridge/` compile with `clang -arch arm64 -fmodules -fobjc-arc` and a macOS 11 minimum.
   `-fmodules` permits Objective-C `@import` statements.
2. Swift uses `-target arm64-apple-macosx11.0 -swift-version 5 -O` and the Objective-C bridge header.
   The link step includes the bridge objects.
3. The private framework path comes from `$(xcrun --show-sdk-path)/System/Library/PrivateFrameworks`.
   The build links `DFRFoundation`, `MultitouchSupport`, `CoreBrightness`, and `CoreDisplay`.
4. The bundle contains the executable, overlay `Info.plist`, default preset, and image files.
5. `codesign --force --sign "MTMR Local Signing"` uses the local identity when present; otherwise `codesign --force --sign -` applies an ad-hoc signature.
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
| The full test runner stops early. | Run later Python files separately and read the first failed assertion. |

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
