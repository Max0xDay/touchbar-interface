# touchbar-interface

A Touch Bar app built on [MTMR](https://github.com/Toxblh/MTMR), with a local socket and the `tbctl` client. Scripts, tools and other projects use the socket to push notifications, button state and panel selection to the bar.

Targets Apple Silicon MacBook Pros with a Touch Bar. Developed and tested on macOS 14.7.6.

## The bar

```
[controls][gap][ left buttons ] |  [ notification area, centred ]  | [ App Controls panel ......... ][switcher]
```

- **Universal control:** a 30 × 30 button opens a separate page with Apple's system brightness and volume sliders; tap it again to return, or hold the main-bar button for 0.5 seconds to return to Apple's Touch Bar. See [layouts.md](docs/layouts.md#universal-control-button).
- **Left space:** available for socket-driven live buttons; Teams controls now live in the right-side Teams panel.
- **Notification area:** shows `tbctl notify` messages and a copy of every macOS notification, with the icon of the sender app.
- **App Controls:** one panel at a time, selected with the switcher at the right edge. The everyday panels are System, Teams, lob, YouTube Music, praatvol, Stats and Fan (VS Code remains available).
- **Teams:** meeting title and elapsed time, with green/red mic and camera controls. One event-driven watcher auto-selects the panel when the meeting window is focused; call end restores the previous panel unless manually changed. Blur stays on Teams. See [app-controls.md](docs/app-controls.md#teams) for verification limits.
- **Fan control:** the Fan panel runs our own fan curves (Apple, Quiet, Cool, Max, Custom) through the [ThermalForge](https://github.com/ProducerGuy/ThermalForge) root daemon.

## Status

| Part | State |
|---|---|
| Native arm64 build (no Xcode, no Rosetta) | Working. |
| Socket and `tbctl` (notify, clear, button, buttons, app, apps, fan, layout) | Working. |
| Notification area (queue, swipe, two-line entries, app icons, macOS notification mirror) | Working. |
| Live buttons and supervised watchers | Working; Teams uses one App Controls watcher instead of two button pollers. |
| App Controls (System, Teams, lob, YouTube Music, praatvol, VS Code, Stats) | Teams implemented and focused-tested; real-call/hardware verification pending. |
| Fan panel and fan control (ThermalForge daemon) | Working; curves to be tuned. |

## Repository layout

```
bin/tbctl          command-line client for the socket
mtmr/
  build.sh         native build of MTMR (Command Line Tools only)
  patches/         our changes to upstream MTMR files (0001-0005, applied in order)
  overlay/         our own Swift files, copied into the build
  tests/           run-tests.sh: Python CLI tests and standalone Swift harnesses
layouts/
  template.json    reference layout for spacing and look
  actual.json      the everyday layout
teams/             Teams debug-port controls, event-driven panel watcher and tap actions
docs/              guides and findings (see below)
build/             build output (git-ignored)
```

## Quick start

```bash
git clone https://github.com/Toxblh/MTMR.git ../MTMR && git -C ../MTMR checkout 94fc98cceff94cf69a2e7c28f726cf35ab93c461
mtmr/build.sh
open build/MTMR.app
bin/tbctl layout actual
bin/tbctl notify "hello"
```

After every rebuild, reset and grant the Accessibility permission again. See [docs/runbook-build-mtmr.md](docs/runbook-build-mtmr.md).

## Documentation

| Document | Content |
|---|---|
| [runbook-build-mtmr.md](docs/runbook-build-mtmr.md) | Build, run, permissions, troubleshooting |
| [layouts.md](docs/layouts.md) | Template and actual layouts, notifications, the macOS notification mirror |
| [live-buttons.md](docs/live-buttons.md) | Socket protocol for buttons, watchers |
| [app-controls.md](docs/app-controls.md) | App Controls panels, data sources, how to add a panel |
| [layout-maths.md](docs/layout-maths.md) | How the layout solver places items |
| [runbook-teams-debug.md](docs/runbook-teams-debug.md) | Teams debug port, mute control, LaunchAgent |
| [findings.md](docs/findings.md) | Facts about the Touch Bar, MTMR, macOS and Teams |

## License

MIT, see [LICENSE](LICENSE). Builds on MTMR (MIT), see [NOTICE](NOTICE).
