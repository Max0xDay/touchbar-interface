# touchbar-interface

A Touch Bar app based on [My TouchBar My Rules (MTMR)](https://github.com/Toxblh/MTMR), with a local socket and `tbctl`.
Scripts and other projects use the socket to send notifications, button state, panel selection, and particle previews.

The app targets Apple Silicon MacBook Pros with a Touch Bar.
The reference machine runs macOS 14.7.6.

## The bar

```text
[universal control][gap][ particle region ] [ notification area, centred ] [ App Controls panel ][switcher]
```

The host measures **1004 × 30 points (pt)**.
The solver uses 1085 pt only before usable bounds exist.
The actual layout contains no left buttons beyond the universal control and the spacer.
Custom layouts can add live buttons.

- The **universal control** measures 30 × 30 pt and opens a separate page.
  The page contains native brightness and volume sliders, each 200 pt wide.
  Tap the control again to return.
  The page also closes after 6 seconds without interaction.
  Hold the main-bar control for at least 0.5 seconds to return to Apple's Touch Bar.
- The **particle region** extends from the left edge to the notification area.
  Adapter connection triggers a green burst.
  Active charging below full capacity adds a sparse green trickle.
  An external Universal Serial Bus (USB) device or external display connection triggers blue sparks.
- The **notification area** shows socket messages and copies of macOS notifications.
  Each display lasts at most 8 seconds.
  A dim dot marks hidden live entries; tap the area to recall the newest entry.
- **App Controls** shows one panel at a time, with the switcher on the right.
  The actual order is System, Teams, lob, YouTube Music, praatvol, Stats, and Fan.
  Visual Studio Code (VS Code) remains available through `tbctl app vscode`.
- The **Teams panel** shows the meeting name above a red elapsed timer.
  Two bordered buttons control the microphone and camera.
  One event-driven watcher selects Teams on meeting-window focus.
  Call end restores the previous panel unless a manual selection cancels restoration.
  Focus loss leaves Teams selected.
- The **Fan panel** controls Apple, Quiet, Cool, Max, and Custom modes through the [ThermalForge](https://github.com/ProducerGuy/ThermalForge) root daemon.

## Status

| Part | State |
|---|---|
| Native arm64 build | The build uses Command Line Tools without full Xcode or Rosetta. |
| Socket and `tbctl` | The client supports notify, clear, button, buttons, app, fan, particles, and layout. |
| Feature commands | The socket also accepts `apps` and `teams`; neither name is a `tbctl` subcommand. |
| Notifications | The queue supports swipe, recall, two-line entries, app icons, and the macOS mirror. |
| Live buttons | The socket updates custom buttons without a layout reload. MTMR supervises watcher processes. |
| App Controls | The registry contains eight panels; the actual layout lists seven. |
| Particles | Power notifications drive the burst and trickle. Device and display events drive blue sparks. |
| Tests | The runner includes six Python files. A known stale notification assertion prevents a clean full-suite result. |

## Repository layout

```text
bin/tbctl          command-line client for the socket and local layout installation
mtmr/
  build.sh         native build with Command Line Tools
  patches/         patches 0001–0006, applied in order
  overlay/         Swift sources copied into the build
  tests/           Python tests and standalone Swift harnesses
layouts/
  template.json    reference layout with an exit button and shape placeholders
  actual.json      everyday layout with universal control and App Controls
teams/             debug-port client, event-driven watcher, and tap scripts
docs/              guides and verified findings
build/             ignored build output
```

## Quick start

Run these commands from this repository:

```bash
git clone https://github.com/Toxblh/MTMR.git ../MTMR
git -C ../MTMR checkout 94fc98cceff94cf69a2e7c28f726cf35ab93c461
mtmr/build.sh
open build/MTMR.app
bin/tbctl layout actual --dry-run
bin/tbctl layout actual
bin/tbctl notify "hello"
```

Grant Accessibility access on first launch.
After each rebuild, reset Accessibility access.
Grant Accessibility access again before further use.
Follow [the build runbook](docs/runbook-build-mtmr.md) for the exact procedure.
Follow [the Teams runbook](docs/runbook-teams-debug.md) to enable Teams controls.
The Fan panel requires a separate ThermalForge installation.

Preview effects without a layout change:

```bash
bin/tbctl particles
bin/tbctl particles --trickle on
bin/tbctl particles --trickle off
bin/tbctl particles --usb
```

Build before the full test suite:

```bash
mtmr/build.sh
bash mtmr/tests/run-tests.sh
```

The build runbook lists separate tests and the known stale notification assertion.

## Documentation

| Document | Content |
|---|---|
| [runbook-build-mtmr.md](docs/runbook-build-mtmr.md) | The runbook covers builds, tests, permissions, and faults. |
| [layouts.md](docs/layouts.md) | The guide covers layouts, universal control, particles, and notifications. |
| [live-buttons.md](docs/live-buttons.md) | The guide defines the socket and watcher contracts. |
| [app-controls.md](docs/app-controls.md) | The guide describes panels, sources, and extension steps. |
| [layout-maths.md](docs/layout-maths.md) | The guide explains geometry and solver rules. |
| [runbook-teams-debug.md](docs/runbook-teams-debug.md) | The runbook covers the debug port, watcher, and controls. |
| [findings.md](docs/findings.md) | The document records platform facts and source evidence. |

## License

The project uses the MIT License; see [LICENSE](LICENSE).
MTMR also uses the MIT License; see [NOTICE](NOTICE).
