# touchbar-interface

A personal Touch Bar product for one MacBook Pro (13", M1, macOS 14.7.6). The project builds [MTMR](https://github.com/Toxblh/MTMR) natively and adds a **local socket**. Scripts, tools and other projects use the socket to push notifications and button state to the bar.

## The bar

```
[✕][gap][ left buttons ] |  [ notification area, centred ]  | [ App Controls panel ......... ][switcher]
```

- **Left buttons:** live buttons that scripts control through the socket. The first two are the Teams mic and camera buttons: green when live, red when muted or off, hidden outside a call. A tap toggles.
- **Notification area:** shows `tbctl notify` messages and a copy of every macOS notification, with the icon of the sender app.
- **App Controls:** one panel at a time, selected with the switcher at the right edge. The panels are System, lob, YouTube Music, VS Code, Stats and Fan.
- **Fan control:** the Fan panel runs our own fan curves (Apple, Quiet, Cool, Max, Custom) through the [ThermalForge](https://github.com/ProducerGuy/ThermalForge) root daemon.

## Status

| Part | State |
|---|---|
| Native arm64 build (no Xcode, no Rosetta) | Working. |
| Socket and `tbctl` (notify, clear, button, buttons, app, apps, fan, layout) | Working. |
| Notification area (queue, swipe, two-line entries, app icons, macOS notification mirror) | Working. |
| Live buttons and watchers (Teams mic, Teams camera) | Working. |
| App Controls (System, lob, YouTube Music, VS Code, Stats) | Working. |
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
  template.json    reference layout for spacing and look (change it only to experiment)
  actual.json      the everyday layout
teams/             Teams mute control through the debug port, the mic watcher and the tap action
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

## Rules for working in this repo

- Record facts in `docs/findings.md`. Say how each fact was established: verified on the machine, read in source, or unverified.
- Back up before you change anything on the machine (configs, LaunchAgents, settings). Keep changes reversible.
- Never use Rosetta 2 or Intel-only binaries.
- Never edit the upstream MTMR clone. Keep changes in `mtmr/patches/` and `mtmr/overlay/`.
